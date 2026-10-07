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
    /// A `sudo pmset` did not stop on SIGTERM and is still running (pid).
    /// It is never SIGKILLed: that could leave a root pmset changing power
    /// state after the journal moved on. Nothing after it was undone, the
    /// journal keeps every entry it had, and the recovery lock stays held
    /// until the command exits: by this process, and by the command itself,
    /// so a crash or force quit cannot free it beside the live pmset. The
    /// end is retried when the command exits, and quit is refused meanwhile
    /// so the app is still there to retry it.
    case privilegedCommandRunning(pid: Int32)
}

/// Why a lifecycle transaction did not run at all.
enum TransactionRefusal: Error, Sendable {
    case lockBusy(String)
    case journalUnreadable(String)
    /// A `sudo pmset` from an earlier transaction is still running and holds
    /// the recovery lock (see `EndOutcome`).
    case commandRunning(pid: Int32)
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
    /// The sudo pmset left running (`unfinishedCommand`), what it holds up
    /// and the pid to stop it by hand. Kept apart from `lastError` so the
    /// command's exit removes it without touching a newer failure: the task
    /// holding the lock for the command clears it then (`holdLock`).
    private(set) var commandWarning: String?

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
    /// What the process table says a pid is now. Read only, to tell whether
    /// a recorded command is still running (`recordedLockHolder`).
    private let processLookup: @Sendable (Int32) -> ProcessLookup
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
    /// Called once an unfinished command has exited, no end is pending and
    /// Low Power Mode has been checked against the journal
    /// (`settleAfterCommand`): `AppServices` replays a lid event refused
    /// while the command ran (`replayLid`), for the state of the latest lid
    /// event once the lid debounce has settled, and runs the floor rules
    /// on the corrected journal. nil in tests that do not wire it.
    var resyncAfterCommand: (@MainActor (_ replayLid: Bool) -> Void)?
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
    /// Set by a lid close, cleared by a lid open. A session that becomes
    /// active (start, or reconcile at launch) takes it from the lid as it
    /// reads then: the lid observer reports changes only, so a session that
    /// starts under a closed lid gets no close call to pause it, and one
    /// that starts after an end with the lid shut must not inherit that
    /// session's pause. Every end clears it.
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
    /// A `sudo pmset` that did not stop on SIGTERM and is still running.
    /// Set by the transaction that ran it, which hands its recovery lock to
    /// a task that releases it when the command exits (`holdLock`); cleared
    /// then. While set, every transaction is refused and quit is deferred;
    /// what a refused one owes is recorded (`Deferred`) and settled once
    /// the command exits. Mirrors run_bounded / stop_transaction in
    /// scripts/backstop.sh.
    @ObservationIgnored private(set) var unfinishedCommand: UnfinishedCommand?
    /// The journal entry `unfinishedCommand` undoes, cleared under its lock
    /// if it exits 0 (`holdLock`).
    @ObservationIgnored private var unfinishedUndo: PendingUndo?
    /// The pid of the recorded command last announced for a busy lock, so
    /// a command that holds the lock across many refusals is announced once.
    @ObservationIgnored private var announcedLockHolder: Int32?
    /// The menu line of the last undo whose journal entry could not be
    /// cleared (`clearUndone`), with the clear it owes. The line goes once
    /// a journal write has that entry cleared, if it is still the one
    /// shown: it says the clear will be retried (`persistState`).
    @ObservationIgnored private var uncleared: (message: String, clear: (inout RuntimeState) -> Void)?
    /// A lid close or open refused while `unfinishedCommand` ran. Replayed
    /// for the lid's latest state once it has exited; cleared then, or by
    /// a session end, which undoes every lid action in the journal.
    @ObservationIgnored private(set) var lidEventDeferred = false
    /// The settle pass waiting to run again after a busy lock.
    @ObservationIgnored private var settleRetry: Task<Void, Never>?
    /// The launch reconcile waiting to run again after a refusal.
    @ObservationIgnored private var reconcileRetry: Task<Void, Never>?
    /// A reconcile found the record of a `sudo pmset` an earlier run left
    /// running, so the session it resumes is owed a Low Power Mode check
    /// (`settleEarlierCommand`). Kept here, not read from disk on each
    /// attempt: `exclusive` removes the record even when it then refuses
    /// the transaction for an unreadable journal. Owed until a reconcile or
    /// start makes a session active and hands it to `settleAfterCommand`;
    /// cleared by a reconcile that leaves no session, and by an end, which
    /// restores the mode from the journal.
    @ObservationIgnored private var earlierCommandCheckOwed = false
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
        processLookup: @escaping @Sendable (Int32) -> ProcessLookup = { SignalProcessControl.processTableState(pid: $0) },
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
        self.appNap = appNap
        self.notifier = notifier
        self.clamshell = clamshell
        self.clock = clock
        self.processLookup = processLookup
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

    /// What a transaction refused while an unfinished command holds the
    /// lock still owes. A Low Power change needs no record: the floors run
    /// again after every exit and ask for it anew. A start or extend is
    /// the user's request; it is refused with a visible error and not
    /// replayed later.
    private enum Deferred {
        /// Kept as `pendingEnd`; retried first when the command exits.
        case end(EndReason)
        /// Replayed for the lid's latest state when the command exits.
        case lidEvent
    }

    /// What a `sudo pmset` left running undoes, if it exits 0
    /// (`stopTransaction`, `holdLock`).
    private enum PendingUndo {
        /// `disablesleep 0`: `sleepDisabledByUs`.
        case sleepRestored
        /// `lowpowermode 0`: `lowPowerSetByUs`, then the display write owed
        /// for the end of the mode.
        case lowPowerOff
    }

    /// Runs `op` after every earlier lifecycle operation, holding the
    /// recovery lock, with `state` freshly read from disk under that lock.
    /// `op` is not run at all when the lock cannot be taken within the
    /// bound or when state.json does not decode: nothing is read, decided
    /// or changed unlocked, and an unreadable journal is never overwritten.
    /// Never blocks the main actor; the wait is polled.
    ///
    /// Refused while an unfinished command runs, `deferred` is recorded in
    /// the refusal itself, before the caller resumes: the command can exit
    /// and its holder settle in between, and must find the work then.
    private func exclusive<T: Sendable>(_ what: String, owes deferred: Deferred? = nil, _ op: @escaping @MainActor @Sendable () async -> T) async -> Result<T, TransactionRefusal> {
        let previous = lifecycleTail
        let task = Task<Result<T, TransactionRefusal>, Never> { @MainActor in
            await previous?.value
            if let stuck = self.unfinishedCommand, stuck.isRunning {
                // The lock is held in this process for that command; waiting
                // for it here would only time out. Refused like a busy lock;
                // the holder settles what is owed when the command exits.
                switch deferred {
                case let .end(reason)?:
                    self.pendingEnd = reason
                    self.quitRequested = false
                case .lidEvent?:
                    self.lidEventDeferred = true
                case nil:
                    break
                }
                self.warnAboutCommand("\(what) skipped, nothing changed: \(stuck.description) is still running and holds the recovery lock until it exits (sudo kill \(stuck.pid) to stop it by hand)")
                return .failure(.commandRunning(pid: stuck.pid))
            }
            let handle: RecoveryLockHandle
            do {
                handle = try await self.recoveryLock.acquire(timeout: self.recoveryLockTimeout)
            } catch {
                self.fail("\(what) skipped, nothing changed: \(error.localizedDescription)\(self.recordedLockHolder(error))")
                return .failure(.lockBusy(error.localizedDescription))
            }
            var lockHandedOver = false
            defer { if !lockHandedOver { handle.release() } }
            // Nothing else holds the lock, so a command recorded as holding
            // it has exited: the record is from a run that crashed or was
            // force-quit while it ran.
            self.announcedLockHolder = nil
            do {
                try self.store.removeUnfinishedCommand()
            } catch {
                Log.error("could not remove \(self.paths.unfinishedCommandFile.path): \(error.localizedDescription)")
            }
            do {
                try self.loadJournal()
            } catch {
                self.refuseForUnreadableJournal(what, error)
                return .failure(.journalUnreadable(error.localizedDescription))
            }
            self.writeOwedEdits()
            let before = self.unfinishedCommand
            // Every `sudo pmset` `op` runs is handed this lock
            // (`PmsetSleepGuard`) and holds it until it exits.
            let result = await RecoveryLock.$held.withValue(handle) { await op() }
            if let stuck = self.unfinishedCommand, stuck !== before {
                // A sudo pmset this transaction ran did not stop on SIGTERM.
                // The lock goes with it, not with the transaction: the
                // command holds it through its own descriptor, and this
                // process keeps one too, so its exit is journaled under the
                // lock before anything else can run (`holdLock`).
                // stop_transaction in backstop.sh keeps it the same way.
                // Handed over even if it has exited since it was reported:
                // the holder is what settles afterwards.
                lockHandedOver = true
                self.holdLock(handle, until: stuck)
            }
            return .success(result)
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

    /// Keep `handle` until `command` exits, then release it and settle what
    /// the stopped transaction, and every one refused meanwhile, left owed
    /// (`settle(after:)`): no timer could know when the command would exit.
    /// The pid is logged the way backstop.sh logs it, so the two logs read
    /// the same.
    ///
    /// Before the release, still under the lock, an undo that exited 0 is
    /// journaled as done (`confirmUndo`) and the record of the command is
    /// removed. Any other exit, a signal included, confirms nothing, and
    /// the retry runs the undo again.
    private func holdLock(_ handle: RecoveryLockHandle, until command: UnfinishedCommand) {
        Log.error("recovery lock kept for \(command.description) until it exits; Insomnia cannot start, end or recover until then; stop it by hand (sudo kill \(command.pid)) and the end is retried when it exits")
        Task { @MainActor [weak self] in
            await command.waitUntilExit()
            let status = command.terminationStatus
            Log.info("\(command.description) exited with status \(status.map(String.init) ?? "?")")
            if let self, self.unfinishedCommand === command {
                if status == 0, let undo = self.unfinishedUndo { self.confirmUndo(undo, by: command) }
                do {
                    try self.store.removeUnfinishedCommand()
                } catch {
                    Log.error("could not remove \(self.paths.unfinishedCommandFile.path): \(error.localizedDescription)")
                }
            }
            handle.release()
            Log.info("recovery lock released")
            guard let self else { return }
            if self.unfinishedCommand === command {
                self.unfinishedCommand = nil
                self.unfinishedUndo = nil
                self.commandWarning = nil
            }
            await self.settle(after: command)
        }
    }

    /// `command`, left running with `undo` owed, has exited 0: the undo is
    /// done, so its entry is cleared before the lock goes. Left set, the
    /// retry would run the same command again, and one that is as slow
    /// every time would be reported as left running every time and never
    /// confirmed. The journal is read from disk first, as by a transaction.
    /// If it cannot be read or written, the entry stays, the retry runs the
    /// undo again, and the menu says so (`clearUndone`) in place of the
    /// command's line, which goes with the exit.
    private func confirmUndo(_ undo: PendingUndo, by command: UnfinishedCommand) {
        let clear: (inout RuntimeState) -> Void
        switch undo {
        case .sleepRestored: clear = { $0.sleepDisabledByUs = false }
        case .lowPowerOff: clear = { $0.lowPowerSetByUs = false }
        }
        do {
            try loadJournal()
        } catch {
            failUncleared("\(command.description) exited 0, but the journal could not be read to clear its entry: \(error.localizedDescription); it will be retried", clear)
            return
        }
        switch undo {
        case .sleepRestored:
            guard clearUndone("sleep restored (\(command.description) exited 0)", clear) else { return }
            Log.info("sleep restored: \(command.description) exited 0")
        case .lowPowerOff:
            guard clearUndone("low power mode switched off (\(command.description) exited 0)", clear) else { return }
            Log.info("low power mode off: \(command.description) exited 0")
            settleDisplayAfterLowPower()
        }
    }

    /// Clear the journal entry of an undo that has been confirmed (the
    /// pmset command exited 0, the pid resumed, the audio or brightness
    /// written), and say whether it was cleared. A write that fails leaves
    /// the entry, so the undo is retried, and is shown in the menu as well
    /// as logged: until it is cleared, the journal still claims a change
    /// that has been undone.
    @discardableResult
    private func clearUndone(_ what: String, _ mutate: @escaping (inout RuntimeState) -> Void) -> Bool {
        do {
            try journal(mutate)
            return true
        } catch {
            failUncleared("\(what) but the journal entry could not be cleared: \(error.localizedDescription); it will be retried", mutate)
            return false
        }
    }

    /// `fail` for an entry left on disk after its undo went through. The
    /// line goes by itself once the entry is cleared (`persistState`).
    private func failUncleared(_ message: String, _ clear: @escaping (inout RuntimeState) -> Void) {
        fail(message)
        uncleared = (message, clear)
    }

    /// For a busy lock: the command recorded as holding it, if any. After a
    /// crash or force quit, that is a `sudo pmset` the earlier run left
    /// running, and nothing else would say why the lock stays busy. The
    /// pid, and `sudo kill` for it, are named only while the live process
    /// has the start time and boot session recorded for the command: once
    /// the command has exited, the pid can belong to an unrelated process.
    /// A record whose command has exited stays until a transaction holds
    /// the lock and removes it (`exclusive`). Announced once per command.
    private func recordedLockHolder(_ error: Error) -> String {
        guard case .busy? = error as? RecoveryLockError, let record = store.loadUnfinishedCommand() else { return "" }
        let command = "`\(record.command)`, left running by Insomnia since \(iso(record.since)),"
        switch (record.identity, processLookup(record.pid)) {
        case let (recorded?, .present(live)) where live.identity == recorded:
            let line = "\(command) still runs as pid \(record.pid) and holds it; stop it by hand with sudo kill \(record.pid)"
            if announcedLockHolder != record.pid {
                announcedLockHolder = record.pid
                notifier.post(
                    title: Self.commandRunningTitle,
                    body: "The recovery lock is busy: \(line). Insomnia changes nothing until the lock is free."
                )
            }
            return "; \(line)"
        case (_?, .absent), (_?, .present):
            return "; \(command) has exited since, so another process holds it"
        case (nil, _), (_?, .unreadable):
            return "; \(command) may still hold it, but Insomnia cannot confirm that pid \(record.pid) is still that command, so it names no process to stop"
        }
    }

    /// Re-establish a consistent state once `command` has exited and its
    /// lock is free, whatever the command did meanwhile. A pending end goes
    /// first and alone: it restores everything. Otherwise the session goes
    /// on and `settleAfterCommand` checks it.
    private func settle(after command: UnfinishedCommand) async {
        if let pending = pendingEnd {
            Log.info("retrying pending end (\(pending.rawValue)) now that \(command.description) has exited")
            await end(reason: pending == .quit ? .user : pending)
            return
        }
        await settleAfterCommand()
    }

    /// The session after an unfinished command has exited, with no end
    /// pending: Low Power Mode is checked against the journal under the
    /// lock (`performLowPowerCheck`), then `resyncAfterCommand` replays a
    /// lid event refused meanwhile and runs the floor rules on the
    /// corrected journal, which also asks again for any Low Power change
    /// refused meanwhile.
    ///
    /// The pass is owed until the check settles, and runs again after
    /// `recoveryRetryDelay` while the session lasts: nothing else would
    /// run it, unlike an end, which the next end request retries. Refused
    /// for a busy lock (another process's transaction) or an unreadable
    /// journal, it checks and replays nothing. A check that could not read
    /// the mode, confirm it off or write the journal still replays the lid
    /// event and runs the floors now, on the flag it could not correct;
    /// they run again once a later check settles. A newer unfinished
    /// command, the check's own `lowpowermode 0` included, settles it when
    /// that one exits. An end that is pending (refused for a busy lock
    /// or an unreadable journal) owes the cleanup instead and the pass is
    /// dropped: the end restores Low Power Mode and the lid actions from
    /// the journal, and the floors must not switch the mode on before it.
    /// Run by the holder; internal for tests.
    func settleAfterCommand() async {
        settleRetry?.cancel()
        settleRetry = nil
        guard session != nil, pendingEnd == nil else { return }
        let checked: Bool
        switch await exclusive("low power check", { await self.performLowPowerCheck() }) {
        case let .success(settled):
            checked = settled
        case .failure(.lockBusy), .failure(.journalUnreadable):
            scheduleSettleRetry()
            return
        case .failure(.commandRunning):
            // A newer command holds the lock; its holder settles when it
            // exits, and the lid event stays recorded until then.
            return
        }
        // A `lowpowermode 0` the check ran was left running: its holder
        // runs this pass again when it exits, and the lid event stays
        // recorded until then.
        guard session != nil, pendingEnd == nil, unfinishedCommand == nil else { return }
        let replayLid = lidEventDeferred
        lidEventDeferred = false
        resyncAfterCommand?(replayLid)
        if !checked { scheduleSettleRetry() }
    }

    private func scheduleSettleRetry() {
        settleRetry?.cancel()
        let delay = recoveryRetryDelay
        settleRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.settleRetry = nil
            Log.info("retrying the low power check after the power command")
            await self.settleAfterCommand()
        }
    }

    /// The journal's Low Power Mode ownership corrected to the mode itself,
    /// read under the lock. A `lowpowermode` command left running keeps the
    /// ownership journaled whatever it then does, so the flag can claim a
    /// mode that is off: a `lowpowermode 1` that failed in the end, or a
    /// rollback `lowpowermode 0` that went through. The floors and
    /// `performSetLowPower` trust the flag and would never switch the mode
    /// on again.
    ///
    /// On: it stays journaled as ours, for the floors or the end to switch
    /// off. Off: a reading is no confirmed undo, and neither is a command
    /// that failed, so the check runs a `lowpowermode 0` of its own and
    /// clears the flag only once that has exited 0, as `restoreAll` does.
    /// A display write owed for the end of the mode is done then, as after
    /// any switch-off. The panel is not checked for movement first: with
    /// the mode already off it may read the value powerd rescaled it to,
    /// which looks the same as a user's change, so the owed value is kept
    /// until the switch-off is confirmed.
    ///
    /// True once nothing is left for this pass to retry: the flag matches
    /// the mode, or the `lowpowermode 0` was itself left running, and the
    /// task holding the lock for it confirms it if it exits 0, or runs the
    /// pass again.
    /// False when the mode could not be read, the `lowpowermode 0` failed,
    /// or the journal could not be written: the flag stays, and
    /// `settleAfterCommand` checks again.
    private func performLowPowerCheck() async -> Bool {
        guard session != nil, state.lowPowerSetByUs else { return true }
        do {
            if try await sleepGuard.isLowPowerModeOn() {
                Log.info("low power mode reads on after the power command; still journaled as ours")
                return true
            }
        } catch {
            Log.error("could not read low power mode after the power command; ownership kept in the journal and checked again in \(Int(recoveryRetryDelay)) s: \(error.localizedDescription)")
            return false
        }
        do {
            try await sleepGuard.setLowPowerMode(false)
        } catch let still as CommandStillRunningError {
            stopTransaction(for: still, thenEnd: nil, undoes: .lowPowerOff)
            return true
        } catch {
            Log.error("low power mode reads off after the power command, but lowpowermode 0 failed; ownership kept in the journal and checked again in \(Int(recoveryRetryDelay)) s: \(error.localizedDescription)")
            return false
        }
        guard clearUndone("low power mode confirmed off after the power command", { $0.lowPowerSetByUs = false }) else { return false }
        Log.info("low power mode confirmed off after the power command; ownership cleared from the journal")
        settleDisplayAfterLowPower()
        return true
    }

    /// A `sudo pmset` did not stop on SIGTERM (`CommandStillRunningError`).
    /// The transaction ends here, like stop_transaction in backstop.sh:
    /// nothing else is undone or changed, the journal keeps every entry it
    /// had (the flag written before the command stays, so the next run
    /// retries it), and `exclusive` hands the lock to the command. The user
    /// is notified once, and `commandWarning` keeps the pid in the menu
    /// until the command exits; the command is also recorded on disk, for
    /// a relaunch to name if this process exits first. `thenEnd` is the end
    /// that owes the cleanup once the command has exited; it is retried
    /// then, and starts are refused and quit deferred meanwhile. Without
    /// one the session goes on, and is checked against the mode once the
    /// command has exited (`settleAfterCommand`). `undoes` is the entry the
    /// command clears if it exits 0 (`holdLock`).
    private func stopTransaction(for error: CommandStillRunningError, thenEnd reason: EndReason?, undoes undo: PendingUndo? = nil) {
        unfinishedCommand = error.command
        unfinishedUndo = undo
        do {
            try store.saveUnfinishedCommand(UnfinishedCommandRecord(
                pid: error.command.pid,
                command: ([error.command.exe] + error.command.args).joined(separator: " "),
                since: clock(),
                identity: error.command.identity
            ))
        } catch {
            Log.error("could not record the command left running in \(paths.unfinishedCommandFile.path): \(error.localizedDescription)")
        }
        warnAboutCommand("\(error.localizedDescription); Insomnia holds the recovery lock and will not quit until it exits (sudo kill \(error.command.pid) to stop it by hand)")
        notifier.post(
            title: Self.commandRunningTitle,
            body: "\(error.command.description) did not stop on SIGTERM and is left running, because killing it could leave a root pmset changing power settings outside the transaction. Nothing else was changed and the journal keeps its entries. Insomnia holds the recovery lock until it exits and will not quit or start a session before then. To stop it by hand: sudo kill \(error.command.pid)."
        )
        if let reason {
            pendingEnd = reason
            quitRequested = false
        }
    }

    /// Lid actions run their journal writes and signals as one transaction
    /// on the same queue. False when the lock could not be taken or the
    /// journal could not be read. Refused while an unfinished command runs,
    /// the lid event is replayed once it has exited.
    @discardableResult
    func runExclusive(_ what: String, _ op: @escaping @MainActor @Sendable () async -> Void) async -> Bool {
        if case .success = await exclusive(what, owes: .lidEvent, op) { return true }
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
        // A start that goes through before a refused launch reconcile runs
        // again drops that reconcile, and takes over its check.
        await settleEarlierCommand()
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
        } catch let still as CommandStillRunningError {
            // Whether the setting was applied is unknown and no second pmset
            // may run beside this one. session.json and the journal stay as
            // written (the backstop honours that deadline if Insomnia dies);
            // the start is undone like an end once the command has exited.
            stopTransaction(for: still, thenEnd: .startFailed)
            return
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
        countdownPaused = clamshell() == true
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
        switch await exclusive("end", owes: .end(reason), { await self.performEnd(reason: reason) }) {
        case let .success(o): outcome = o
        case .failure(.lockBusy): outcome = .locked
        case .failure(.journalUnreadable): outcome = .journalUnreadable
        case let .failure(.commandRunning(pid)): outcome = .privilegedCommandRunning(pid: pid)
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
        case .privilegedCommandRunning:
            // No timer either: the task holding the lock for the command
            // retries the end the moment it exits. Nothing is recorded
            // here: the refusal or the stopped end recorded `pendingEnd`
            // before that task could run, and it may already have run and
            // finished the end, which writing it again would undo. Starts
            // are refused and quit is deferred until then.
            break
        }
        return outcome
    }

    private func performEnd(reason: EndReason) async -> EndOutcome {
        let had = session != nil
        Log.info("session end (\(reason.rawValue))")
        stopTimers()
        countdownPaused = false
        session = nil
        // Every lid action is undone from the journal below, or by the
        // retry of this end, and Low Power Mode restored from it: a lid
        // event refused earlier, a settle pass waiting to run again and
        // the check owed for an earlier run's command owe nothing.
        lidEventDeferred = false
        settleRetry?.cancel()
        settleRetry = nil
        earlierCommandCheckOwed = false
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
        let stuck = await restoreAll()
        services?.stop()

        if let stuck {
            // restoreAll stopped at a sudo pmset that did not stop on SIGTERM
            // and has told the user (stopTransaction). Nothing after it was
            // undone and the journal keeps its entries; the lock goes to the
            // command and this end runs again when it exits. Reached from
            // reconcile and a failed start too, so the pending end is
            // recorded here, not only in `end()`.
            pendingEnd = reason
            quitRequested = false
            return .privilegedCommandRunning(pid: stuck.pid)
        }

        if state.isDirty || retainedBecause != nil {
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
            if let retainedBecause {
                // The agent enforces deadlines, it does not remove a live
                // session file; only this process can, so it stays to retry.
                let journalNote = state.isDirty ? " Some changes are also still journaled." : ""
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
            } catch let still as CommandStillRunningError {
                // No rollback beside a live pmset. Ownership stays journaled
                // until the command has exited; the mode is read then, and
                // a mode that reads off is switched off once more before
                // the ownership is cleared (`performLowPowerCheck`).
                stopTransaction(for: still, thenEnd: nil)
                return false
            } catch {
                fail("could not enable low power mode: \(error.localizedDescription)")
                do {
                    try await sleepGuard.setLowPowerMode(false)
                    clearUndone("low power mode switched off after the failed enable") { $0.lowPowerSetByUs = false }
                } catch let still as CommandStillRunningError {
                    // The rollback itself is left running, and the lock
                    // stays with it. Ownership stays journaled until it has
                    // exited: cleared if it exits 0, the mode read otherwise
                    // (`performLowPowerCheck`).
                    stopTransaction(for: still, thenEnd: nil, undoes: .lowPowerOff)
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
                clearUndone("low power mode switched off") { $0.lowPowerSetByUs = false }
                Log.info("low power mode off")
                settleDisplayAfterLowPower()
                return true
            } catch let still as CommandStillRunningError {
                // Ownership stays journaled until the command has exited:
                // cleared if it exits 0, the mode read otherwise; the
                // floors run again either way.
                stopTransaction(for: still, thenEnd: nil, undoes: .lowPowerOff)
                return false
            } catch {
                Log.error("could not disable low power mode: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Undo every lid-close action recorded on disk: resume frozen pids,
    /// clear the Docker marker, restore volume and mute. Used by lid open.
    /// Refused while an unfinished command runs, the lid event is replayed
    /// once it has exited.
    func undoLidActions() async {
        _ = await exclusive("lid open", owes: .lidEvent) { self.undoLidActionsInJournal() }
    }

    // MARK: Restore

    /// Undo every RuntimeState entry of the journal read under the current
    /// transaction's lock. Each undo is journaled as soon as it succeeds,
    /// through the live journal rather than a copy, so a write that lands
    /// while pmset is running (a lid-close freeze, say) is never overwritten.
    /// Failures, a journal entry that could not be cleared after its undo
    /// included (`clearUndone`), are logged and shown in the menu, and the
    /// entry is left set so the next end, reconcile or the backstop
    /// retries it.
    ///
    /// A `sudo pmset` that does not stop on SIGTERM ends the restore right
    /// there, as stop_transaction does in backstop.sh: no later undo runs
    /// beside the live command, and the journal stays as it was. That
    /// command is returned; the caller (`performEnd`) reports the end as
    /// stopped and it is retried once the command has exited.
    func restoreAll() async -> UnfinishedCommand? {
        if state.sleepDisabledByUs {
            do {
                try await sleepGuard.setSleepDisabled(false)
                clearUndone("sleep restored") { $0.sleepDisabledByUs = false }
                Log.info("sleep restored")
            } catch let still as CommandStillRunningError {
                stopTransaction(for: still, thenEnd: nil, undoes: .sleepRestored)
                return still.command
            } catch {
                fail("could not restore sleep: \(error.localizedDescription)")
            }
        }

        var lowPowerJustCleared = false
        if state.lowPowerSetByUs {
            dropDisplayWriteIfMoved()
            do {
                try await sleepGuard.setLowPowerMode(false)
                clearUndone("low power mode cleared") { $0.lowPowerSetByUs = false }
                Log.info("low power mode cleared")
                lowPowerJustCleared = true
            } catch let still as CommandStillRunningError {
                stopTransaction(for: still, thenEnd: nil, undoes: .lowPowerOff)
                return still.command
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
        return nil
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
        if !state.frozenProcesses.isEmpty {
            let report = processControl.resume(state.frozenProcesses)
            // Only entries that still need a retry, or that a person has to
            // look at, stay journaled. Gone and resumed entries are done.
            let keep = Set(report.failed + report.unverifiable + report.unobserved)
            clearUndone("frozen processes resumed") { s in
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
                fail("pid(s) \(list) are stopped but journaled without identity, so Insomnia cannot prove it froze them and will not resume them. Either an older build recorded the pid alone, or a freeze stopped the pid and Insomnia quit, crashed or failed to write before the stop was confirmed in the journal. Check each one first, for example `ps -o pid,stat,lstart,command -p <pid>`, and only if it is a process you expected Insomnia to freeze run `kill -CONT <pid>`; the entry stays in the journal until resumed or gone")
            }
        } else if state.dockerFrozen {
            clearUndone("Docker Desktop has no frozen process left") { $0.dockerFrozen = false }
        }

        if state.savedOutputVolume != nil || state.savedMuted != nil {
            do {
                let current = try audio.read()
                let volume = state.savedOutputVolume ?? current.volume
                let muted = state.savedMuted ?? current.muted
                try audio.apply(volume: volume, muted: muted)
                Log.info("audio restored (volume \(volume), muted \(muted))")
                clearUndone("audio restored") { s in
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
                clearUndone("display brightness restored") { s in
                    s.savedDisplayBrightness = nil
                    s.displayRestoredUnderLowPower = underLowPower ? saved : nil
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
                clearUndone("keyboard backlight restored") { $0.savedKeyboardBrightness = nil }
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

    /// Run at launch. A refused reconcile changed nothing and runs again
    /// after `recoveryRetryDelay` until it goes through. Nothing else would
    /// resume a session still live on disk: its sleep stays disabled until
    /// the backstop's deadline, with no battery floor watching it. The lock
    /// can stay busy past the bound for as long as a command an earlier run
    /// left running takes to exit, and a journal that does not decode may
    /// be fixed by hand.
    ///
    /// The command recorded by that run has exited once the reconcile holds
    /// the lock, and may have changed Low Power Mode after the journal was
    /// written. A session resumed after it is checked against the mode, as
    /// after a command this process left running (`settleAfterCommand`).
    /// The check stays owed across refusals, and goes to a session a start
    /// makes active first (`earlierCommandCheckOwed`).
    func reconcile() async {
        reconcileRetry?.cancel()
        reconcileRetry = nil
        await reconcile(ticket: endTicket, isRetry: false)
    }

    private func reconcile(ticket: Int, isRetry: Bool) async {
        // This process removes the record of its own command when that
        // command exits, so a record on disk now was left by an earlier run.
        if store.loadUnfinishedCommand() != nil { earlierCommandCheckOwed = true }
        let result = await exclusive("reconcile") { () -> Bool in
            if isRetry, !self.reconcileIsOwed(since: ticket) { return false }
            await self.performReconcile()
            return true
        }
        switch result {
        case .success(true):
            // No session: the journal held no claim, or an end restores it.
            if session == nil { earlierCommandCheckOwed = false }
            await settleEarlierCommand()
        case .success(false):
            break
        case .failure:
            scheduleReconcileRetry(ticket: ticket)
        }
    }

    /// Hand the check owed for an earlier run's command to the session a
    /// reconcile or start has just made active. Without one it stays owed.
    private func settleEarlierCommand() async {
        guard earlierCommandCheckOwed, session != nil else { return }
        earlierCommandCheckOwed = false
        await settleAfterCommand()
    }

    private func scheduleReconcileRetry(ticket: Int) {
        reconcileRetry?.cancel()
        let delay = recoveryRetryDelay
        reconcileRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconcileRetry = nil
            guard self.reconcileIsOwed(since: ticket) else { return }
            Log.info("retrying the launch reconcile")
            await self.reconcile(ticket: ticket, isRetry: true)
        }
    }

    /// A refused reconcile is moot once a start has made a session active
    /// or an end has been requested: the start replaced the session on
    /// disk and took over the Low Power check, and restoring the journal is
    /// the end's job from then on.
    /// Checked before the retry queues and again once it holds the lock.
    private func reconcileIsOwed(since ticket: Int) -> Bool {
        guard session == nil, endTicket == ticket else {
            Log.info("launch reconcile dropped: a session was started or an end requested since it was refused")
            return false
        }
        return true
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
            } catch let still as CommandStillRunningError {
                // Not surfaced: the session file and journal stay for the end
                // that runs once the command has exited.
                session = nil
                stopTransaction(for: still, thenEnd: .recoveryUnavailable)
                return
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
            countdownPaused = lidClosed == true
            await armDeadline(s.endsAt)
            applyAppNapInJournal()
            services?.start(for: self)
            return
        }

        // Step 1: missing or expired -> full end. A restore stopped at a
        // sudo pmset that did not stop on SIGTERM ends the reconcile too:
        // step 3 would run a second `disablesleep 0` beside the live one.
        // The lock goes to the command and the end is retried when it exits.
        if onDisk != nil {
            Log.info("reconcile: session expired, restoring")
            if case .privilegedCommandRunning = await performEnd(reason: .timer) { return }
        } else if state.isDirty {
            Log.info(keptSessionFile != nil
                ? "reconcile: session.json kept in place, restoring the journal as for an expired session"
                : "reconcile: no session but dirty state, restoring")
            if case .privilegedCommandRunning = await performEnd(reason: .backstop) { return }
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
        // The entry a failed clear left is gone once its clear changes no
        // undo entry of what was written, or nothing is left to undo,
        // whichever write did it. The display write owed after Low Power
        // Mode is left out: a retry made once the mode is off owes none,
        // where the failed clear did.
        if let (message, clear) = uncleared {
            var cleared = s
            clear(&cleared)
            if cleared.undoEntries == s.undoEntries || !s.isDirty {
                if lastError == message { lastError = nil }
                uncleared = nil
            }
        }
    }

    /// Logs `message` and shows it in the status menu until the next
    /// success clears it.
    func fail(_ message: String) {
        lastError = message
        Log.error(message)
    }

    private func warnAboutCommand(_ message: String) {
        commandWarning = message
        Log.error(message)
    }

    private func iso(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }

    static let incompleteTitle = "Restore incomplete"
    static let notEndedTitle = "Session not ended"
    static let journalTitle = "Recovery journal unreadable"
    static let commandRunningTitle = "Power command still running"
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
