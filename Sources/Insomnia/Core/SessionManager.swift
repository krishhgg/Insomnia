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
    /// agent, read the sleep setting, or journal for it, so it ended the
    /// session instead of holding sleep with nothing to release it.
    case recoveryUnavailable
    /// The administrator password dialog that turns sleep off was cancelled,
    /// answered wrongly, timed out, or pmset failed behind it, during start.
    /// The setting may still have been applied, so the start is undone from
    /// the journal like an end rather than rolled back from memory.
    case startFailed
    /// Reconcile found a valid session on disk but `pmset -g` no longer
    /// reports SleepDisabled: something turned sleep back on while Insomnia
    /// was not running. Turning it off again needs a password, which a
    /// relaunch must never ask for, so the session ends instead.
    case sleepReenabled
}

/// What `end` achieved. Callers that are about to quit need to know whether
/// leaving now abandons anything.
enum EndOutcome: Sendable, Equatable {
    /// Journal clean, machine restored. The one entry that may remain is
    /// the saved volume of an output device that was not connected: it
    /// waits for the device (`SessionManager.outputDevicesChanged`, or a
    /// later launch) and the notification and the menu name it.
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

    /// Whether a quit may go ahead after an end with this outcome
    /// (`AppDelegate.applicationShouldTerminate`): only once nothing is
    /// left that this process alone can finish.
    var letsQuitGo: Bool {
        switch self {
        case .restored, .incomplete(agentArmed: true): true
        case .locked, .incomplete(agentArmed: false), .sessionRetained, .journalUnreadable, .privilegedCommandRunning: false
        }
    }
}

/// Why a lifecycle transaction did not run at all. A busy lock and an
/// unreadable journal carry the line the refusal put in the menu
/// (`lastError`).
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
    /// How many times `fail` has run, so an undo can tell a line it put up
    /// from one left by an earlier run.
    @ObservationIgnored private var failCount = 0
    /// Reconcile found SleepDisabled set with no session and no journal
    /// claim: something other than Insomnia disabled sleep. Kept apart from
    /// `lastError` so a restore failure from the same reconcile stays
    /// visible beside it. Cleared by a session start, or by
    /// `recheckForeignSleep()` once the bit reads 0 again.
    private(set) var foreignSleepWarning: String?
    /// Why this transaction could not remove the pending-start marker, or
    /// nil once it is gone. While it is set, a dialog from an earlier start
    /// could still turn sleep off, so `restoreAll` keeps the sleep entry
    /// journaled, starts are refused, and the menu keeps the line.
    @ObservationIgnored private(set) var markerProblem: String?
    /// Why the start the journal still records (`sleepOffAttempt`) is not
    /// settled, or nil when no start is recorded. Set by every settlement;
    /// a new start is refused with it.
    @ObservationIgnored private var attemptProblem: String?
    /// Why the sleep undo of that start is held back, or nil when it runs.
    /// Set by every settlement: a command for that start may still act
    /// (undecided), or the receipt shows its command never turned sleep
    /// off and no earlier restore is owed, but the journal could not record
    /// that. `restoreAll` then runs no pmset for sleep, so a SleepDisabled
    /// 1 another tool set stays and a pmset still running for that start is
    /// not raced. Never set for a settled record.
    @ObservationIgnored private var attemptHold: String?
    /// The nonce of the start the journal still records when this process
    /// rolled it back as one whose command never turned sleep off
    /// (`abandonStart`: no dialog was shown, the command's status said it
    /// stopped before its write, or the receipt showed it) but could not
    /// journal that. Every later settlement of that start in this process
    /// takes it as the verdict, whatever the receipt shows: a command whose
    /// second read found another tool's 1 and that could not write
    /// `refused` over its record stops with 6 and leaves its `writing`,
    /// which on its own would undo the start and set that 1 to 0. Only this
    /// process saw the status: a relaunch, backstop.sh and uninstall.sh
    /// settle from the receipt alone.
    @ObservationIgnored private var refusedNonce: String?
    /// The sudo pmset left running (`unfinishedCommand`), what it holds up
    /// and the pid to stop it by hand. Kept apart from `lastError` so the
    /// command's exit removes it without touching a newer failure: the task
    /// holding the lock for the command clears it then (`holdLock`).
    private(set) var commandWarning: String?
    /// UIDs of output devices whose saved volume could not be restored
    /// because they were not connected at the last try. Each try decides
    /// again: a device that came back and then failed to restore is no
    /// longer in it. In memory: each launch finds them again at its first
    /// try.
    private(set) var audioDevicesNotConnected: Set<String> = []
    /// The menu line (`lastError`) the restore of the saved output volumes
    /// last put up: a device change or audio retry that was refused, or a
    /// restore that failed. A later restore that leaves nothing to retry
    /// takes it down, unless a newer failure has replaced it since
    /// (`clearAudioWarning`).
    @ObservationIgnored private var audioWarning: String?

    /// Output devices lid close muted that are still waiting to get their
    /// volume and mute back because they were not connected. The menu
    /// names each one, with a way to stop waiting.
    var outputsWaitingForRestore: [SavedAudioOutput] {
        state.savedAudioOutputs.filter { audioDevicesNotConnected.contains($0.deviceUID) }
    }

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

    /// A journal write for a brightness kept after a refused restore, on a
    /// build whose guard allows the call, that the disk refused. Applied
    /// only while the entry still holds that value and its flag.
    private enum KeptEdit: Equatable {
        /// The level was found set since: the entry goes, with no write.
        case clear(Float)
        /// The saved level was written: the entry goes. A display level
        /// written under Insomnia's Low Power Mode still owes its write
        /// once the mode is off, as when the clear lands at once
        /// (`displayRestoredUnderLowPower`).
        case restored(Float, underLowPower: Bool)
        /// The write failed: the flag goes, so the entry is an ordinary
        /// failed restore, retried like any other and counted as dirty by
        /// backstop.sh and uninstall.sh.
        case unflag(Float)

        var saved: Float {
            switch self {
            case .clear(let value), .restored(let value, _), .unflag(let value): value
            }
        }

        var isUnflag: Bool {
            if case .unflag = self { return true }
            return false
        }

        /// A clear, of a level set since or restored, while the journal
        /// `s` still holds the entry with that value and its flag. Lost, it
        /// leaves that entry for the next launch to read again.
        func clearsEntry(in s: RuntimeState, saved: KeyPath<RuntimeState, Float?>, flag: KeyPath<RuntimeState, Bool>) -> Bool {
            !isUnflag && s[keyPath: flag] && s[keyPath: saved] == self.saved
        }

        func apply(to s: inout RuntimeState, saved: WritableKeyPath<RuntimeState, Float?>, flag: WritableKeyPath<RuntimeState, Bool>, restoredUnderLowPower: WritableKeyPath<RuntimeState, Float?>? = nil) {
            guard s[keyPath: flag], s[keyPath: saved] == self.saved else { return }
            if !isUnflag { s[keyPath: saved] = nil }
            s[keyPath: flag] = false
            if case .restored(let value, let underLowPower) = self, let restoredUnderLowPower {
                s[keyPath: restoredUnderLowPower] = underLowPower ? value : nil
            }
        }

        /// The log line once the edit is written.
        func written(_ what: String) -> String {
            switch self {
            case .clear(let value): "\(what) \(value), set since its refused restore, cleared from the journal"
            case .restored(let value, _): "\(what) \(value), restored, cleared from the journal"
            case .unflag(let value): "\(what) \(value), whose restore failed, marked in the journal for retry"
            }
        }
    }

    private struct OwedEdits {
        var freeze = UndoneFreeze()
        var display: KeptEdit?
        var keyboard: KeptEdit?
        /// The display write owed after Low Power Mode was dropped or done
        /// (`clearDisplayWriteAfterLowPower`).
        var displayWriteAfterLowPowerCleared = false
        /// Insomnia's Low Power Mode went off (`clearLowPowerOwnership`).
        var lowPowerOff = false
        /// The kept display entry with this value read above 0
        /// (`noteKeptDisplayReadLit`). Applied only while the entry still
        /// holds that value and its flag. An end does not let quit go
        /// while it is owed (`performEnd`).
        var displayReadLit: Float?

        var isEmpty: Bool {
            freeze.isEmpty && display == nil && keyboard == nil && !displayWriteAfterLowPowerCleared && !lowPowerOff && displayReadLit == nil
        }

        /// An unflag still owed leaves a failed restore on disk looking
        /// like one no build can make, which backstop.sh and uninstall.sh
        /// pass over: only this process can finish it.
        var hidesARestore: Bool { display?.isUnflag == true || keyboard?.isUnflag == true }

        /// A kept entry settled, as set since or restored, whose clear the
        /// journal `s` has not taken. On disk the entry still reads as
        /// kept, so a launch after a quit reads it again, and writes the
        /// saved value over a 0 the user set since. An end does not let
        /// quit go while one is owed (`performEnd`).
        func settlesAKeptEntry(in s: RuntimeState) -> Bool {
            display?.clearsEntry(in: s, saved: \.savedDisplayBrightness, flag: \.displayRestoreRefused) == true
                || keyboard?.clearsEntry(in: s, saved: \.savedKeyboardBrightness, flag: \.keyboardRestoreRefused) == true
        }

        var keptLines: [String] {
            [display?.written("display brightness"), keyboard?.written("keyboard backlight"),
             displayReadLit.map { "display brightness \($0), kept after a refused restore, journaled as read above 0" }].compactMap { $0 }
        }

        var lowPowerLines: [String] {
            [displayWriteAfterLowPowerCleared ? "display write owed after low power mode cleared from the journal" : nil,
             lowPowerOff ? "low power mode, switched off, cleared from the journal" : nil].compactMap { $0 }
        }

        /// Kept entries settled, as set since or restored, whose clear the
        /// journal has not taken: the re-read keeps going for them, since
        /// outside a session its transactions are what retry the write.
        var clearsWaiting: [String] {
            [("display brightness", display), ("keyboard backlight", keyboard)].compactMap { what, edit in
                switch edit {
                case .clear(let value)?: "\(what) \(value), set since its refused restore, still to be cleared from the journal"
                case .restored(let value, _)?: "\(what) \(value), restored, still to be cleared from the journal"
                case .unflag?, nil: nil
                }
            }
        }

        func apply(to s: inout RuntimeState) {
            freeze.apply(to: &s)
            // Before the display's edit, so a restore owed after the
            // clear keeps its own write after the mode.
            if displayWriteAfterLowPowerCleared { s.displayRestoredUnderLowPower = nil }
            display?.apply(to: &s, saved: \.savedDisplayBrightness, flag: \.displayRestoreRefused, restoredUnderLowPower: \.displayRestoredUnderLowPower)
            keyboard?.apply(to: &s, saved: \.savedKeyboardBrightness, flag: \.keyboardRestoreRefused)
            if lowPowerOff { s.lowPowerSetByUs = false }
            // After the display's edit: a reading of an entry since
            // settled or unflagged is about no entry.
            if let lit = displayReadLit, s.displayRestoreRefused, s.savedDisplayBrightness == lit {
                s.keptDisplayReadLit = lit
            }
        }
    }

    /// Edits not on disk yet because the disk refused them too. Applied
    /// before every journal write and dropped once one succeeds, and tried
    /// on their own at the start of every transaction, so a lid close or
    /// any other write never works from an entry this process already
    /// settled. In memory only: after a relaunch, reconcile finds the pids
    /// of an undone freeze running and clears their entries itself, reads
    /// a kept brightness again, and switches off once more a Low Power
    /// Mode still journaled as ours, which changes nothing. A kept
    /// brightness read again could get its saved value written over a 0
    /// set since, so an end does not let quit go while the clear of one
    /// is owed (`OwedEdits.settlesAKeptEntry`), nor while a failed
    /// restore's flag or a reading above 0 is.
    private var owedEdits = OwedEdits()

    /// The journal as it reads once the owed edits are written: what is
    /// frozen right now, which brightness is still Insomnia's to restore,
    /// and whether Insomnia's Low Power Mode is on. The status menu and the
    /// sampler read this, not `state`.
    var effectiveState: RuntimeState {
        var s = state
        owedEdits.apply(to: &s)
        return s
    }

    /// The journal has said, at some point in this run, that Insomnia's own
    /// Low Power Mode is on in this boot, or this run switched off a claim
    /// on the mode. The mode rescales the panel, and once it is off macOS
    /// brings the panel back over a time nobody has measured, so from then
    /// on no display reading in this run is taken as the level the user
    /// set (`keptDisplayReadDoubt`). A display entry kept after a refused
    /// restore is journaled as such for later runs in the same boot
    /// (`RuntimeState.keptDisplayUnderLowPower`). A claim read from before
    /// the Mac last started (`RuntimeState.lowPowerClaimFromEarlierBoot`)
    /// does not set it by itself. Switching that claim off in this boot
    /// does, whatever the mode reads (`readLowPowerClaimedBeforeRestart`,
    /// `clearLowPowerOwnership`), and so does enabling the mode.
    @ObservationIgnored private var lowPowerWasOurs = false

    /// `kern.bootsessionuuid` of this run, for `keptDisplayUnderLowPower`.
    private let bootSession: String

    /// Why a reading of the display does not show the level set since a
    /// value kept after a refused restore, or nil when it may: under
    /// Insomnia's Low Power Mode it reads the mode's rescaled value, and
    /// after it, a value on its way back. Such a value is never adopted:
    /// the entry stays. A relaunch is no sign the panel is back, so the
    /// entry is journaled as one the mode was on over, and later runs read
    /// it with the same doubt until the Mac restarts.
    var keptDisplayReadDoubt: String? {
        let s = effectiveState
        if s.lowPowerSetByUs, !lowPowerWasOurs, s.lowPowerClaimFromEarlierBoot(boot: bootSession) {
            return "while our low power mode, journaled on before the Mac last started, may still be on, which rescales it"
        }
        if s.lowPowerSetByUs { return "under our low power mode, which rescales it" }
        if lowPowerWasOurs { return "after our low power mode was or may have been on in this run, which rescales it until some time after it goes off" }
        if s.keptDisplayReadUnderLowPower(inBoot: bootSession) {
            return "after our low power mode was or may have been on over it since the Mac last started, which rescales it until some time after it goes off"
        }
        return nil
    }

    /// Fire date of the single deadline timer, exposed for tests and the menu.
    private(set) var scheduledDeadline: Date?

    let store: Store
    let paths: Paths
    private let sleepGuard: any SleepGuarding
    private let processControl: any ProcessSignaling
    private let backstop: any BackstopScheduling
    /// The root-owned record of what the command behind a start's password
    /// dialog did, read to settle a start the journal still records.
    private let receipts: SleepOffReceipts
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
    /// How long a transaction waits for the root command behind a password
    /// dialog to let go of the pending-start marker before it gives up on
    /// removing it for this run. pmset itself takes well under a second.
    private let markerLockTimeout: TimeInterval
    /// How long a start or a settlement waits for the receipt's lock
    /// (`SleepOffReceipts.lock`), which the root command behind a dialog
    /// holds from before its checks until pmset exits.
    private let receiptLockTimeout: TimeInterval
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
    /// The pending in-process retry of the saved output volumes
    /// (`scheduleAudioRetry`). One at a time.
    @ObservationIgnored private var audioRetryTask: Task<Void, Never>?
    /// Retries left before `scheduleAudioRetry` stops, until the next
    /// device change, lid open, end or launch tries again.
    @ObservationIgnored private var audioRetriesLeft = SessionManager.audioRetryLimit
    static let audioRetryLimit = 10
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
    /// Set when a session.json beside a pending-start marker that no
    /// journaled start accounts for could not be removed
    /// (dropSessionOfUnrecordedMarker): reconcile ends that session rather
    /// than resume it.
    @ObservationIgnored private var unrecordedMarkerSession = false
    /// What the one-time lid-close update changed at init, posted by the
    /// launch reconcile (`announceLidCloseUpdate`). Settings shows the same
    /// change (`Config.lidCloseDefaultsNotice`) for a user who has
    /// notifications turned off.
    @ObservationIgnored private var pendingLidCloseNotice: LidCloseDefaultsChange?

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
        receipts: SleepOffReceipts,
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
        markerLockTimeout: TimeInterval = 10,
        receiptLockTimeout: TimeInterval = 10,
        reassertDelay: Duration = .seconds(2),
        keptRecheckDelay: Duration = .seconds(3),
        keptRecheckAttempts: Int = 20,
        keptRecheckSlowDelay: Duration = .seconds(60),
        bootSession: String = SignalProcessControl.bootSession
    ) {
        self.paths = paths
        self.store = Store(paths: paths)
        self.sleepGuard = sleepGuard
        self.processControl = processControl
        self.backstop = backstop
        self.receipts = receipts
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
        self.markerLockTimeout = markerLockTimeout
        self.receiptLockTimeout = receiptLockTimeout
        self.reassertDelay = reassertDelay
        self.keptRecheckDelay = keptRecheckDelay
        self.keptRecheckAttempts = keptRecheckAttempts
        self.keptRecheckSlowDelay = keptRecheckSlowDelay
        self.bootSession = bootSession

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
        self.lowPowerWasOurs = loadedState.map { $0.lowPowerSetByUs && !$0.lowPowerClaimFromEarlierBoot(boot: bootSession) } ?? false
        self.lastError = loadError
        if var c = (try? store.loadConfig()) ?? nil {
            // Settings keeps the end floor below the Low Power Mode floor; a
            // hand-edited config.json may not. Fix it here and write it back.
            var corrections = c.normalizeFloors().map { [$0] } ?? []
            // Once for a config.json an earlier build saved: written back
            // with the mark, so a setting the user turns back stays back.
            let earlierBuild = !c.lidCloseDefaultsApplied
            let lidClose = c.applyLidCloseDefaults()
            if earlierBuild {
                corrections.append("lid-close update: " + (lidClose.map(\.changes) ?? "nothing to change"))
            }
            if !corrections.isEmpty {
                let change = corrections.joined(separator: "; ")
                do {
                    try store.saveConfig(c)
                    Log.info("config.json: \(change); saved")
                } catch {
                    // The corrections apply in memory either way; the file
                    // stays as it was and is corrected again next launch.
                    Log.error("config.json: \(change); could not save the correction: \(error.localizedDescription)")
                }
            }
            self.config = c
            self.pendingLidCloseNotice = lidClose
        } else {
            // A fresh install: the defaults already are the update, and
            // `Config()` carries its mark, so there is nothing to announce.
            self.config = Config()
            try? store.saveConfig(self.config)
        }
        do {
            try audio.onDevicesChanged { [weak self] in
                Task { @MainActor in await self?.outputDevicesChanged() }
            }
        } catch {
            Log.error("\(error.localizedDescription); an output device still muted from a lid close gets its volume back at the next lid open, session end or launch instead of when it reconnects")
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
            backstop: LaunchdBackstop(paths: paths, agentLock: Paths.standard.recoveryLock),
            receipts: .live,
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
                let line = "\(what) skipped, nothing changed: \(error.localizedDescription)\(self.recordedLockHolder(error))"
                self.fail(line)
                return .failure(.lockBusy(line))
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
            // Holding the lock means no start is waiting on a password
            // dialog, so a marker left on disk belongs to an abandoned one.
            // One that cannot be removed does not stop the transaction:
            // restores still run, and `markerProblem` holds back only the
            // clearing of the sleep entry and any new start.
            let clearing = await self.clearPendingStart()
            do {
                try self.loadJournal()
            } catch {
                return .failure(.journalUnreadable(self.refuseForUnreadableJournal(what, error)))
            }
            // A start the journal still records is settled from the
            // receipt, whatever happened to its marker: deleting the marker
            // does not stop a command for that start, the receipt's lock
            // and the start's expiry do.
            if self.state.sleepOffAttempt != nil {
                await self.settleSleepOffAttempt()
            } else {
                self.attemptProblem = nil
                self.attemptHold = nil
                self.refusedNonce = nil
                if case .cleared(file: _?) = clearing { self.dropSessionOfUnrecordedMarker() }
            }
            self.writeOwedEdits()
            self.settleDisplayAfterUnreadOff()
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
        if claimsLowPowerInThisBoot(state) { lowPowerWasOurs = true }
    }

    /// `s` journals Insomnia's Low Power Mode, by a claim not read from
    /// before the Mac last started (`lowPowerWasOurs`).
    private func claimsLowPowerInThisBoot(_ s: RuntimeState) -> Bool {
        s.lowPowerSetByUs && !s.lowPowerClaimFromEarlierBoot(boot: bootSession)
    }

    /// Returns the line put in the menu.
    private func refuseForUnreadableJournal(_ what: String, _ error: Error) -> String {
        let message = Self.unreadableJournalMessage(error)
        let line = "\(what) refused, nothing changed: \(message)"
        fail(line)
        let detail = error.localizedDescription
        if announcedCorruption != detail {
            announcedCorruption = detail
            notifier.post(title: Self.journalTitle, body: message)
        }
        return line
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
    ///
    /// A `lowpowermode 0` with a display write owed after the mode, by
    /// what this process last read, is known done even when the journal
    /// cannot be read: its clear is owed as for a journal that refuses it,
    /// and the write waits for the first transaction that reads the journal
    /// again (`displayWriteAfterUnreadOff`). The unreadable file is not
    /// written. Left to the retry, that write would meet a panel the
    /// mode's end rescaled and be dropped as moved by the user
    /// (`dropDisplayWriteIfMoved`).
    private func confirmUndo(_ undo: PendingUndo, by command: UnfinishedCommand) {
        let clear: (inout RuntimeState) -> Void
        switch undo {
        case .sleepRestored: clear = { $0.sleepDisabledByUs = false }
        case .lowPowerOff: clear = { $0.lowPowerSetByUs = false }
        }
        do {
            try loadJournal()
        } catch {
            if case .lowPowerOff = undo, let owed = effectiveState.displayRestoredUnderLowPower {
                // Switched off in this boot, a claim from before the
                // restart included (`clearLowPowerOwnership`).
                if state.lowPowerSetByUs { lowPowerWasOurs = true }
                owedEdits.lowPowerOff = true
                displayWriteAfterUnreadOff = owed
                failUncleared("\(command.description) exited 0, but the journal could not be read to clear its entry: \(error.localizedDescription); low power mode is off, and the clear and the display write owed after it (\(owed)) wait for the journal to read again", clear)
                return
            }
            failUncleared("\(command.description) exited 0, but the journal could not be read to clear its entry: \(error.localizedDescription); it will be retried", clear)
            return
        }
        switch undo {
        case .sleepRestored:
            if let problem = markerProblem {
                // As in `restoreAll`: a dialog behind the marker could still
                // turn sleep off, so the entry stays.
                Log.error("sleep restored (\(command.description) exited 0), but its journal entry is kept")
                fail(Self.markerProblemText(problem))
                return
            }
            if state.unsettledSleepOffAttempt != nil {
                // As in `restoreAll`: only a settlement removes a start the
                // journal still records, and the entry stays with it.
                Log.error("sleep restored (\(command.description) exited 0), but its journal entry stays with the start the journal still records")
                return
            }
            guard clearUndone("sleep restored (\(command.description) exited 0)", clear) else { return }
            Log.info("sleep restored: \(command.description) exited 0")
        case .lowPowerOff:
            clearLowPowerOwnership("low power mode switched off (\(command.description) exited 0)")
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

    /// A `lowpowermode 0` exited 0 while the journal could not be read
    /// (`confirmUndo`): the display write owed after the mode then, by
    /// what this process had last read. nil when none was owed.
    @ObservationIgnored private var displayWriteAfterUnreadOff: Float?

    /// The first transaction that reads the journal again after
    /// `displayWriteAfterUnreadOff` makes that write, as `confirmUndo`
    /// would have at the exit, if the journal read back, with the owed
    /// edits, still owes that value with the mode not ours. Any other
    /// journal (replaced, edited, or one whose entry went meanwhile) gets
    /// no write: what it owes is decided as for any journal.
    private func settleDisplayAfterUnreadOff() {
        guard let carried = displayWriteAfterUnreadOff else { return }
        displayWriteAfterUnreadOff = nil
        let journaled = effectiveState
        guard journaled.displayRestoredUnderLowPower == carried, !journaled.lowPowerSetByUs else {
            Log.info("display write owed after low power mode (\(carried)) not made: the journal read back after the switch-off does not owe it")
            return
        }
        Log.info("journal readable again after low power mode went off; writing the display owed after it")
        settleDisplayAfterLowPower()
    }

    /// Insomnia's Low Power Mode is off: a `lowpowermode 0` exited 0. Its
    /// ownership is cleared like any confirmed undo (`clearUndone`). If the
    /// journal refuses, the entry stays on disk and in the menu, and the
    /// clear is owed as well (see `owedEdits`): the mode is off all the
    /// same, so the display write owed after it goes now, as when the clear
    /// lands. Left for a retry, it would meet a panel the mode's end has
    /// rescaled, which reads like a level the user set, and be dropped.
    /// Until a write lands the disk still claims the mode, so an end, the
    /// floors or the agent may switch it off once more, as after any
    /// failed clear. Returns whether the journal took the clear.
    /// A claim from before the Mac last started is ours in this boot once
    /// it is switched off in it, whatever the mode read before: it may
    /// have been on until a moment before (`readLowPowerClaimedBeforeRestart`).
    /// So the write that clears it records the kept display entry for this
    /// boot, as does the next one that lands if this one is refused.
    @discardableResult
    private func clearLowPowerOwnership(_ what: String) -> Bool {
        if state.lowPowerSetByUs { lowPowerWasOurs = true }
        guard !clearUndone(what, { $0.lowPowerSetByUs = false }) else { return true }
        owedEdits.lowPowerOff = true
        return false
    }

    /// `failUncleared` for an undo that reports its errors in one message:
    /// returns the line for that message. The line goes by itself once the
    /// entry is cleared if it is the whole message.
    private func unclearedLine(_ message: String, _ clear: @escaping (inout RuntimeState) -> Void) -> String {
        uncleared = (message, clear)
        return message
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
                // On in this boot, whenever the claim was written.
                lowPowerWasOurs = true
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
        let cleared = clearLowPowerOwnership("low power mode confirmed off after the power command")
        if cleared {
            Log.info("low power mode confirmed off after the power command; ownership cleared from the journal")
        }
        settleDisplayAfterLowPower()
        return cleared
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
    /// Ordering: a check that the installed backstop.sh can void the
    /// dialog (BackstopVersion), then session.json, then state.json, then
    /// the recovery agent, then the pending-start marker, then the password
    /// dialog that runs `pmset disablesleep 1`. A failure before the dialog is rolled back:
    /// nothing has touched the machine. So is a cancelled dialog or an
    /// osascript that never started, which ran nothing as root: no pmset
    /// runs, so a sleep setting someone else owns is left alone. Any other
    /// failure is ambiguous (the setting may have been applied before the
    /// error or timeout), so it is undone from the journal like an end, and
    /// the journal keeps the entry until that undo is confirmed.
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
        if let problem = markerProblem {
            // The dialog behind that marker may still turn sleep off, or
            // its command may still be running. Nothing is written.
            // The menu keeps the marker's own line, which goes with it.
            let text = Self.markerProblemText(problem)
            Log.error("start refused, nothing changed")
            fail(text)
            notifier.post(title: Self.endTitle(.startFailed, had: false), body: "Nothing was changed: \(text)")
            return
        }
        if let recorded = state.sleepOffAttempt {
            // An earlier start the journal still records is not settled:
            // its dialog can still be answered, its receipt could not be
            // read, or the journal could not be updated with what the
            // receipt shows. Or it is settled, but its claim on the
            // receipt was not given back yet. A new start would replace
            // that record.
            let text = Self.recordedStartText(recorded, attemptProblem)
            fail("start refused, nothing changed: \(text)")
            notifier.post(title: Self.endTitle(.startFailed, had: false), body: "Nothing was changed: \(text).")
            return
        }
        do {
            // Only a backstop.sh that deletes the marker can void the
            // dialog below if this process dies under it.
            try backstop.checkVoidsPrompts()
        } catch {
            fail("start refused, nothing changed: \(error.localizedDescription)")
            notifier.post(title: Self.endTitle(.startFailed, had: false), body: "Nothing was changed: \(error.localizedDescription).")
            return
        }
        do {
            // The record the root command keeps of what it did. Without a
            // safe one, nothing could show later that a failed or abandoned
            // start never turned sleep off. Claimed below, under its lock.
            _ = try receipts.identity()
        } catch {
            let text = "the receipt \(receipts.file) that shows whether a start turned sleep off is missing or unsafe (\(error.localizedDescription)). Run scripts/install.sh again"
            fail("start refused, nothing changed: \(text)")
            notifier.post(title: Self.endTitle(.startFailed, had: false), body: "Nothing was changed: \(text).")
            return
        }
        do {
            // A SleepDisabled 1 the journal does not own is someone else's
            // setting, and this session's end would turn it back on, so
            // Start leaves it alone, as a cancelled dialog does. Whether
            // the end can turn sleep back on without a password is asked of
            // sudo later, by the root command before it writes anything:
            // this app's end and backstop.sh both run `sudo -n`, and
            // without the rule they would fail at the deadline and leave
            // sleep off.
            try await sleepGuard.checkSleepSettingForStart(sleepOffIsOurs: state.sleepDisabledByUs)
        } catch {
            fail("start refused, nothing changed: \(error.localizedDescription)")
            notifier.post(title: Self.endTitle(.startFailed, had: false), body: "Nothing was changed: \(error.localizedDescription).")
            return
        }
        let now = clock()
        var new = SessionMath.newSession(now: now, duration: duration, maxDuration: config.maxDuration)
        new.id = UUID().uuidString
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

        // The claim on the receipt, under its lock: the receipt's nonce now
        // is this start's predecessor, and the release file shows this
        // start's nonce held until it is settled, so no start from another
        // Insomnia folder can replace the line its settlement reads. The
        // journal records the attempt before the claim is written, so a
        // crash between the two leaves a record whose settlement finds no
        // claim to give back.
        let held: SleepOffReceipts.Guard
        do {
            held = try await receipts.lock(timeout: receiptLockTimeout)
        } catch {
            let text = "the receipt \(receipts.file) could not be locked to claim it (\(error.localizedDescription))"
            fail("start refused, nothing changed: \(text)")
            notifier.post(title: Self.endTitle(.startFailed, had: false), body: "Nothing was changed: \(text).")
            return
        }
        let predecessor: String
        do {
            predecessor = try receipts.claimable(under: held)
        } catch {
            held.release()
            let text = "the receipt \(receipts.file) cannot be claimed: \(error.localizedDescription)"
            fail("start refused, nothing changed: \(text)")
            notifier.post(title: Self.endTitle(.startFailed, had: false), body: "Nothing was changed: \(text).")
            return
        }

        // The command the dialog runs as root turns sleep off only while the
        // pending-start marker holds this attempt's nonce (see below), the
        // receipt still holds `predecessor`, and before `expires`, set when
        // the marker is written. It reads `pmset -g` again as root, since
        // another tool may turn sleep off while the password is typed,
        // unless the journal owned a 1 before this start, for which Start's
        // own read was skipped too.
        var pending = PendingStart(marker: store.paths.pendingStartFile, nonce: UUID().uuidString, deadline: new.endsAt, sleepOffIsOurs: journalBefore.sleepDisabledByUs, predecessor: predecessor, receipt: held.identity)
        var attempt = SleepOffAttempt(nonce: pending.nonce, owedBefore: journalBefore.sleepDisabledByUs, receipt: held.identity, predecessor: predecessor, deadline: pending.deadlineSeconds, expires: pending.expiresSeconds, marker: nil, session: new.id)
        do {
            try journal {
                $0.sleepDisabledByUs = true
                $0.sleepOffAttempt = attempt
            }
        } catch {
            held.release()
            fail("could not write session: \(error.localizedDescription)")
            rollBackStart(journal: journalBefore, session: sessionBefore)
            return
        }
        do {
            try receipts.writeRelease(.held(attempt.nonce))
        } catch {
            // The claim may be half written: put back what it showed. A
            // claim that landed all the same is given back by the
            // settlement, and the record stays until then, so it is never
            // left with no record to account for it. No dialog was shown.
            try? receipts.writeRelease(.free(predecessor))
            held.release()
            fail("could not claim the receipt: \(error.localizedDescription)")
            await abandonStart(attempt, journal: journalBefore, session: sessionBefore)
            return
        }
        held.release()
        do {
            // A crash from here leaves a record whose settlement finds no
            // dialog, gives the claim back, puts the entry back and removes
            // this session.json.
            try store.saveSession(new)
            keptSessionFile = nil
        } catch {
            fail("could not write session: \(error.localizedDescription)")
            await abandonStart(attempt, journal: journalBefore, session: sessionBefore)
            return
        }

        // The agent is confirmed loaded before sleep is disabled, so a crash
        // at any later point already has launchd polling the deadline.
        do {
            try await backstop.arm()
        } catch {
            fail("could not arm backstop: \(error.localizedDescription)")
            await abandonStart(attempt, journal: journalBefore, session: sessionBefore)
            return
        }
        guard endTicket == ticket else {
            Log.info("start abandoned before disabling sleep: end requested meanwhile")
            await abandonStart(attempt, journal: journalBefore, session: sessionBefore)
            return
        }

        // The pending-start marker: the command the dialog runs as root
        // turns sleep off only while this file holds this attempt's nonce,
        // and keeps it locked until pmset exits. It is deleted below on
        // every outcome, before this transaction lets go of the lock, and
        // by whoever takes the lock next if this process dies first, so a
        // dialog answered after its start was abandoned changes nothing.
        // Its identity goes in the journal before the dialog: a marker
        // that is not this file when it goes may have been replaced while
        // a command for this start held it, and then the receipt is not
        // trusted.
        // `expires` bounds how long any command for this start can still
        // write: the dialog's own limit and grace from now, or the
        // session's end if sooner. Journaled with the marker, so every
        // settlement knows when a receipt that still holds the predecessor
        // proves something.
        pending.expires = min(new.endsAt, clock().addingTimeInterval(AdministratorPrompt.answerWindow))
        attempt.expires = pending.expiresSeconds
        let markerFile: FileIdentity
        do {
            markerFile = try store.savePendingStart(pending.nonce)
        } catch {
            // No marker with this nonce exists, so no dialog was shown.
            fail("could not write the pending-start marker: \(error.localizedDescription)")
            await clearPendingStart()
            await abandonStart(attempt, journal: journalBefore, session: sessionBefore)
            return
        }
        attempt.marker = markerFile.text
        do {
            try journal { $0.sleepOffAttempt = attempt }
        } catch {
            // No dialog was shown.
            fail("could not journal the pending-start marker: \(error.localizedDescription)")
            attempt.marker = nil
            await clearPendingStart()
            await abandonStart(attempt, journal: journalBefore, session: sessionBefore)
            return
        }

        // The administrator password dialog. This is the only call that can
        // prompt, and Start is the only path that reaches it: the user just
        // pressed Enter, so someone is at the keyboard. A cancel, a wrong
        // password, a root command that refused, a timeout or a pmset
        // failure all land here.
        // The marker goes on every outcome below before anything is
        // restored, and a marker that cannot go keeps the sleep entry
        // journaled (see restoreAll).
        do {
            try await sleepGuard.disableSleep(pending)
        } catch let AdministratorPromptError.stillRunning(prompt, grace) {
            // The prompt's process did not stop on SIGTERM. Nothing is
            // killed. The marker goes first, under its lock, so an answer
            // that still comes cannot turn sleep off. Only the file this
            // start wrote counts: one put in its place may have been
            // swapped in after the command locked the original.
            let cleared = await clearPendingStart(expecting: markerFile)
            let alive = prompt.osascriptAlive
            if cleared != .kept {
                // The command behind the dialog now finds no marker and
                // stops at that check, and any command for this start
                // refuses once `expires` has passed, so nothing here waits
                // for the process: the start is settled from the receipt,
                // under its lock, once `expires` has passed (a few seconds
                // from now), and the recovery lock goes with this
                // transaction. The leftover process is reported, and
                // watched on its own until it exits.
                reportStuckPrompt(prompt, grace: grace, osascriptAlive: alive, voided: true)
                watchVoidedPrompt(prompt, grace: grace)
                await endFailedStart(attempt, dialogOver: false, journal: journalBefore, session: sessionBefore, error: AdministratorPromptError.stillRunning(prompt, grace: grace).localizedDescription)
                return
            }
            // A root command already past its check holds the marker's
            // lock and may still run pmset (or the marker cannot be
            // deleted): nothing is rolled back beside it. session.json, the
            // journal entry and the recovery lock stay until the prompt
            // exits, the same rule a stuck `sudo pmset` gets. The user is
            // told what is running and, while it is osascript itself, how
            // to stop it. Then the rollback.
            reportStuckPrompt(prompt, grace: grace, osascriptAlive: alive, voided: false)
            if alive {
                // The pid is ours to name only until osascript exits; a
                // root command it started can keep its output open longer.
                await prompt.waitUntilOsascriptExits()
                if prompt.isRunning {
                    fail("start: \(Self.stuckPromptText(prompt, grace: grace, osascriptAlive: false, voided: false))")
                }
            }
            await prompt.waitUntilExit()
            // The command that held the marker's lock has exited with the
            // prompt, so the marker can go before the receipt is read.
            let text = "\(prompt) did not finish in time and has now exited; rolling the start back"
            await clearPendingStart()
            fail("could not disable sleep: \(text)")
            await endFailedStart(attempt, dialogOver: false, journal: journalBefore, session: sessionBefore, error: text)
            return
        } catch let error as AdministratorPromptError where error.nothingToUndo {
            // Cancelled, osascript never started, or the root command
            // refused: the start was over or expired, the session had
            // ended, sudo did not confirm a passwordless restore, `pmset -g`
            // showed a 1 this start did not set, or the receipt was locked,
            // unsafe or held another start's line. Every refusal comes
            // before the sleep write, so nothing is left for an undo to
            // reverse. The claim is given back, the journal and
            // session.json go back exactly as they were and no pmset runs,
            // so a sleep setting another tool made, even while the dialog
            // was up, is left alone. Nothing can use this attempt's marker
            // any more, so one that cannot be deleted does not hold the
            // rollback back; it is reported, and the next transaction tries
            // it again.
            await clearPendingStart()
            fail("could not disable sleep: \(error.localizedDescription)")
            if await abandonStart(attempt, journal: journalBefore, session: sessionBefore) {
                notifier.post(title: Self.endTitle(.startFailed, had: false), body: "No session was started, and Insomnia undid anything it changed: \(error.localizedDescription).")
            }
            return
        } catch {
            // A wrong password, a signal, a timeout, a pmset failure: the
            // status cannot say whether root's write came first, but the
            // receipt can, under its lock. osascript exited by itself only
            // for `.failed`: then its dialog is over, and no command for
            // it can start any more.
            await clearPendingStart()
            fail("could not disable sleep: \(error.localizedDescription)")
            let over = (error as? AdministratorPromptError)?.dialogOver ?? false
            await endFailedStart(attempt, dialogOver: over, journal: journalBefore, session: sessionBefore, error: error.localizedDescription)
            return
        }
        await clearPendingStart()
        // Sleep is off and journaled as ours; the record of the attempt has
        // nothing left to show. Under the receipt's lock the record is
        // marked settled first, then the claim goes back and the record
        // goes. Left unsettled, the record is settled by the next
        // transaction, which keeps the sleep entry: the receipt shows this
        // start's `writing`. Left settled, the next transaction finishes it.
        await finishAttempt(attempt, resuming: new)
        guard endTicket == ticket else {
            // Sleep is disabled and journaled as ours. The end that was
            // requested runs next and restores from that journal; the session
            // is never surfaced.
            Log.info("start abandoned after disabling sleep: end requested meanwhile; journal left for it")
            return
        }

        session = new
        clearLastError()
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
        clearLastError()
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

        // An output device that is not connected does not hold up the end:
        // its saved volume stays journaled for when it reconnects, and the
        // notification and the menu name it.
        let waiting = outputsWaitingForRestore
        let waitingUIDs = Set(waiting.map(\.deviceUID))
        let dirty = journalNeedsRestore(leavingOutAudioOf: waitingUIDs)
        // A reading above 0 of the kept display entry that the journal has
        // not taken is in this process only. The agent never needs it,
        // but the next launch does: without it, a 0 the user sets reads as
        // the darkening never undone and gets the kept value. So quit
        // waits until it reaches the disk, as for a hidden failed restore.
        let owedReadLit = owedEdits.displayReadLit
        // So is a kept entry this process settled, as set since or
        // restored, whose clear the journal has not taken. On disk the
        // entry still reads as kept: the next launch would read it again
        // and write the saved value over a 0 the user sets meanwhile. Quit
        // waits for that clear too.
        let owedSettlement = owedEdits.settlesAKeptEntry(in: state)
        if dirty || retainedBecause != nil || owedReadLit != nil || owedSettlement {
            // The journal is the retry list. Make sure something will read it.
            var armed = true
            if dirty {
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
                let journalNote = dirty ? " Some changes are also still journaled." : ""
                notifier.post(
                    title: Self.incompleteTitle,
                    body: "\(retainedBecause)\(journalNote) Insomnia retries in \(Int(recoveryRetryDelay)) s; do not quit until it is gone."
                )
                scheduleEndRetry(reason)
                return .sessionRetained
            }
            // The agent reads only the disk. A failed restore whose flag is
            // still owed reads there as one no build can make, and the agent
            // passes over it, so this process keeps it and quit waits until
            // the restore lands or the flag is off the disk.
            if armed, owedEdits.hidesARestore {
                Log.info("end: the recovery agent cannot see a failed brightness restore whose flag the journal has not taken; Insomnia retries it itself")
            }
            if let owedReadLit {
                Log.info("end: the journal has not taken that display brightness \(owedReadLit), kept after a refused restore, read above 0; a relaunch without it would write that value over a 0 set since, so Insomnia keeps it and retries")
            }
            if owedSettlement {
                Log.info("end: the journal has not taken the clear of a brightness kept after a refused restore and settled in this process; a relaunch would read that entry again and could write its saved value over a 0 set since, so Insomnia keeps it and retries")
            }
            let agentCanFinish = armed && !owedEdits.hidesARestore && owedReadLit == nil && !owedSettlement
            let unrecorded = [owedSettlement ? "that a brightness kept after a refused restore is settled" : nil,
                              owedReadLit != nil ? "a reading of the display brightness kept after a refused restore" : nil]
            let detail = dirty ? (lastError ?? "some changes could not be undone")
                : "state.json could not record \(unrecorded.compactMap { $0 }.joined(separator: ", nor "))"
            let retry: String
            if agentCanFinish {
                // The agent keeps saved output volumes, display brightness
                // and keyboard backlight but cannot restore them (CoreAudio,
                // private frameworks). This process retries the volumes on
                // its own; the brightness waits for a later end or launch.
                let owesAudio = state.savedAudioOutputs.contains { !waitingUIDs.contains($0.deviceUID) }
                    || state.savedOutputVolume != nil || state.savedMuted != nil
                // With the owed edits applied: a brightness this process
                // already settled is not owed.
                let journaled = effectiveState
                let owesBrightness = journaled.savedDisplayBrightness != nil || journaled.savedKeyboardBrightness != nil
                var sentences: [String] = []
                if state.isDirtyApartFromAppOnlyEntries { sentences.append("The recovery agent retries every minute.") }
                if owesAudio { sentences.append(Self.audioRetrySentence(recoveryRetryDelay)) }
                if owesBrightness { sentences.append(Self.brightnessRetrySentence) }
                retry = sentences.joined(separator: " ")
            } else if owedReadLit != nil || owedSettlement {
                retry = "Insomnia retries in \(Int(recoveryRetryDelay)) s; do not quit until state.json can be written."
            } else {
                retry = "Insomnia retries in \(Int(recoveryRetryDelay)) s; do not quit until it is restored."
            }
            notifier.post(title: Self.incompleteTitle, body: "\(detail). \(retry)")
            // Reconcile and a failed start reach here without `end()`; the
            // retry is scheduled here so they are covered too (rescheduling
            // from `end()` is harmless).
            if !agentCanFinish { scheduleEndRetry(reason) }
            return .incomplete(agentArmed: agentCanFinish)
        }
        notifier.post(title: Self.endTitle(reason, had: had), body: endBody(reason, waiting: waiting))
        return .restored
    }

    /// What an end checks before it reports a restore. A brightness kept
    /// after a refused restore is left out of `isDirty`, since no build
    /// whose guard refuses it can restore it, and so is one waiting for a
    /// reading it can trust: nothing failed, and it is read again. It
    /// counts once this build wrote it and the write failed, which clears
    /// the flag, on disk or as an owed edit if the journal refused that too.
    /// The saved audio of `devices` is left out (`RuntimeState.isDirty(leavingOutAudioOf:)`).
    private func journalNeedsRestore(leavingOutAudioOf devices: Set<String>) -> Bool {
        state.isDirty(leavingOutAudioOf: devices) || owedEdits.hidesARestore
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
        // A claim the disk holds from before the Mac last started is not
        // ours in this boot by itself; one this write sets is.
        let claimFromEarlierBoot = state.lowPowerClaimFromEarlierBoot(boot: bootSession)
        s.noteLowPowerOverKeptDisplay(ours: lowPowerWasOurs || (s.lowPowerSetByUs && !claimFromEarlierBoot), boot: bootSession)
        s.dropKeptDisplayReadLitUnlessKept()
        try persistState(s)
        for line in owedEdits.keptLines + owedEdits.lowPowerLines { Log.info(line) }
        owedEdits = OwedEdits()
    }

    /// Take the entries of an undone freeze off the journal now, or with
    /// the next journal write that succeeds. Only for `LidActions.freeze`,
    /// inside its transaction.
    func clearUndoneFreeze(_ undone: UndoneFreeze) {
        owedEdits.freeze.pids.formUnion(undone.pids)
        owedEdits.freeze.docker = owedEdits.freeze.docker || undone.docker
        writeOwedEdits()
    }

    private func writeOwedEdits() {
        guard !owedEdits.isEmpty else { return }
        do {
            try journal { _ in }
        } catch {
            if !owedEdits.freeze.isEmpty {
                Log.error("could not clear the entries of an undone freeze from the journal: \(error.localizedDescription); the status leaves them out, and the next journal write takes them off")
            }
            if !owedEdits.keptLines.isEmpty {
                Log.error("could not write the brightness edits owed to the journal: \(error.localizedDescription); the next journal write or transaction tries again")
            }
            if !owedEdits.lowPowerLines.isEmpty {
                Log.error("could not write the low power mode edits owed to the journal: \(error.localizedDescription); the next journal write or transaction tries again")
            }
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
            if effectiveState.displayRestoredUnderLowPower != nil {
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
                    clearLowPowerOwnership("low power mode switched off after the failed enable")
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
            await readLowPowerClaimedBeforeRestart()
            dropDisplayWriteIfMoved()
            do {
                try await sleepGuard.setLowPowerMode(false)
                clearLowPowerOwnership("low power mode switched off")
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

    /// Before a `lowpowermode 0` for a claim on the mode from before the
    /// Mac last started (`RuntimeState.lowPowerClaimFromEarlierBoot`): the
    /// claim says nothing about this boot, and neither does a read of the
    /// mode. On, the switch-off ends it in this boot. Off, the user or
    /// another tool may have switched it off a moment ago. Either way the
    /// panel may be on its way back from it, over a time nobody has
    /// measured, so the mode counts as ours in this run (`lowPowerWasOurs`)
    /// and the kept display entry is recorded for this boot. A mode off
    /// since long before this launch waits the same way, since no reading
    /// tells the two apart: its entry stays until a launch after the next
    /// restart. The read is logged and decides nothing.
    private func readLowPowerClaimedBeforeRestart() async {
        guard !lowPowerWasOurs, state.lowPowerClaimFromEarlierBoot(boot: bootSession) else { return }
        lowPowerWasOurs = true
        do {
            if try await sleepGuard.isLowPowerModeOn() {
                Log.info("low power mode, journaled as ours before the Mac last started, reads on; it is switched off as ours in this boot")
            } else {
                Log.info("low power mode, journaled as ours before the Mac last started, reads off; it may have gone off only a moment ago, with the panel still on its way back, so it is switched off as ours in this boot")
            }
        } catch {
            Log.error("could not read low power mode, journaled as ours before the Mac last started; it is switched off as ours in this boot: \(error.localizedDescription)")
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
    /// The sleep entry is cleared only when this transaction removed the
    /// pending-start marker before the restore. Otherwise a dialog left on
    /// screen could still turn sleep off after this point, or its root
    /// command may still be running: sleep is restored all the same, but
    /// the entry stays as the record that the bit may be Insomnia's, so the
    /// end reports itself incomplete and every later run retries. Nor is
    /// it cleared while the journal still records a start that is not
    /// settled (`sleepOffAttempt`): only that start's settlement decides
    /// it, and the entry goes with the restore after that. For such a
    /// start no sleep pmset runs at all while `attemptHold` says why: a
    /// command for it may still act, or its receipt shows its command
    /// never turned sleep off and no earlier restore is owed. A settled
    /// record already decided the entry, and changes nothing here.
    ///
    /// A `sudo pmset` that does not stop on SIGTERM ends the restore right
    /// there, as stop_transaction does in backstop.sh: no later undo runs
    /// beside the live command, and the journal stays as it was. That
    /// command is returned; the caller (`performEnd`) reports the end as
    /// stopped and it is retried once the command has exited.
    func restoreAll() async -> UnfinishedCommand? {
        if state.sleepDisabledByUs, state.unsettledSleepOffAttempt != nil, let hold = attemptHold {
            Log.info("sleep entry kept, and sleep left as it is: \(hold)")
        } else if state.sleepDisabledByUs {
            do {
                try await sleepGuard.enableSleep()
                Log.info("sleep restored")
                if let problem = markerProblem {
                    Log.error("sleep restored, but its journal entry is kept")
                    fail(Self.markerProblemText(problem))
                } else if state.unsettledSleepOffAttempt != nil {
                    // A command for that start may have turned sleep off,
                    // or the journal could not record its settlement. A
                    // settled record decided the entry already.
                    Log.error("sleep restored, but its journal entry stays with the start the journal still records")
                } else {
                    clearUndone("sleep restored") { $0.sleepDisabledByUs = false }
                }
            } catch let still as CommandStillRunningError {
                stopTransaction(for: still, thenEnd: nil, undoes: .sleepRestored)
                return still.command
            } catch {
                fail("could not restore sleep: \(error.localizedDescription)")
            }
        }

        var lowPowerJustCleared = false
        if state.lowPowerSetByUs {
            await readLowPowerClaimedBeforeRestart()
            dropDisplayWriteIfMoved()
            do {
                try await sleepGuard.setLowPowerMode(false)
                clearLowPowerOwnership("low power mode cleared")
                Log.info("low power mode cleared")
                lowPowerJustCleared = true
            } catch let still as CommandStillRunningError {
                stopTransaction(for: still, thenEnd: nil, undoes: .lowPowerOff)
                return still.command
            } catch {
                fail("could not clear low power mode: \(error.localizedDescription)")
            }
        } else if effectiveState.displayRestoredUnderLowPower != nil {
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

    /// Restores each output device lid close muted, on that device only:
    /// the default output never stands in for one that is not connected. A
    /// device that reads unmuted was unmuted after the close, by the user
    /// or by another app, so the volume it has now stands and only its
    /// entry goes. A device that is not connected keeps its entry, at a lid
    /// open as at the session end, and gets it back when it reconnects
    /// (`outputDevicesChanged`) or at a later launch. Whether a device is
    /// connected is decided afresh on each try: only this try's
    /// `AudioDeviceMissingError` puts it in `audioDevicesNotConnected`. The
    /// entry an earlier build wrote, without the device, is restored on the
    /// default output, as that build did, after the others. Each entry
    /// leaves the journal only once its restore went through. A restore
    /// that fails on a connected device, or whose journal clear fails, is
    /// tried again in process (`scheduleAudioRetry`); `retrying` says this
    /// is that retry. A pass that leaves nothing to retry takes down the
    /// menu line an earlier audio failure put up (`clearAudioWarning`).
    private func restoreAudioInJournal(retrying: Bool = false) {
        if !retrying { audioRetriesLeft = Self.audioRetryLimit }
        var retry = false
        for entry in state.savedAudioOutputs where state.savedAudioOutputs.contains(entry) {
            let device = entry.label
            let wasWaiting = audioDevicesNotConnected.remove(entry.deviceUID) != nil
            do {
                let now = try audio.read(deviceUID: entry.deviceUID)
                if now.muted {
                    try audio.apply(volume: entry.volume, muted: entry.muted, deviceUID: entry.deviceUID)
                    Log.info("audio restored on \(device) (volume \(entry.volume), muted \(entry.muted))")
                } else {
                    Log.info("audio: \(device) was unmuted after the lid close; left at volume \(now.volume), the saved volume \(entry.volume) is dropped")
                }
            } catch is AudioDeviceMissingError {
                audioDevicesNotConnected.insert(entry.deviceUID)
                if !wasWaiting {
                    Log.info("audio: \(device), muted at lid close, is not connected; its saved volume stays in the journal until it reconnects, and no other output is touched")
                }
                continue
            } catch {
                failAudio("could not restore audio on \(device): \(error.localizedDescription); kept in the journal to retry")
                retry = true
                continue
            }
            let uid = entry.deviceUID
            if !clearUndone("audio restored on \(device)", { $0.savedAudioOutputs.removeAll { $0.deviceUID == uid } }) {
                retry = true
            }
        }

        if state.savedOutputVolume != nil || state.savedMuted != nil {
            do {
                var volume = state.savedOutputVolume
                var muted = state.savedMuted
                if volume == nil || muted == nil {
                    // Half an entry (a hand edit): the missing value is the
                    // default output's current one.
                    let current = try audio.read()
                    volume = volume ?? current.volume
                    muted = muted ?? current.muted
                }
                let v = volume ?? 1
                let m = muted ?? false
                try audio.apply(volume: v, muted: m, deviceUID: nil)
                Log.info("audio restored on the default output (volume \(v), muted \(m))")
                let cleared = clearUndone("audio restored") { s in
                    s.savedOutputVolume = nil
                    s.savedMuted = nil
                }
                if !cleared { retry = true }
            } catch {
                failAudio("could not restore audio: \(error.localizedDescription)")
                retry = true
            }
        }

        if retry {
            scheduleAudioRetry()
        } else {
            audioRetryTask?.cancel()
            audioRetryTask = nil
            clearAudioWarning()
        }
    }

    /// `fail` for the restore of the saved output volumes.
    private func failAudio(_ message: String) {
        fail(message)
        audioWarning = message
    }

    /// The saved output volumes owe no retry now: the menu line their last
    /// failure put up goes, if it is still the line shown. A newer failure
    /// of anything else stays.
    private func clearAudioWarning() {
        if let line = audioWarning, lastError == line { lastError = nil }
        audioWarning = nil
    }

    /// CoreAudio reports a device connected or gone. An output device still
    /// owed its volume gets it back now if it is connected, unless a lid
    /// close may be in effect (`lidCloseMayBeInEffect`): the lid open
    /// restores it then. CoreAudio sends no second event, so a recovery
    /// lock that refuses this one is retried in process. Whether anything
    /// is owed is decided in the transaction, on the journal as it is on
    /// disk: another copy of the app may have saved an output since this
    /// copy last read it.
    func outputDevicesChanged() async {
        await restoreOwedAudio("output device change", retrying: false)
    }

    /// One transaction over the journal as it is on disk: restores the saved
    /// output volumes unless a lid close may be in effect, and schedules
    /// the in-process retry when the transaction is refused (a busy lock,
    /// a power command still running, an unreadable journal).
    private func restoreOwedAudio(_ what: String, retrying: Bool) async {
        let result = await exclusive(what) {
            let s = self.state
            guard !s.savedAudioOutputs.isEmpty || s.savedOutputVolume != nil || s.savedMuted != nil else {
                // Nothing saved, or restored meanwhile by a lid open, an
                // end or another copy of the app.
                self.clearAudioWarning()
                return
            }
            if self.lidCloseMayBeInEffect() {
                Log.info("audio: \(what) while a lid close may be in effect; the saved volumes wait for the lid open")
                return
            }
            self.restoreAudioInJournal(retrying: retrying)
        }
        guard case let .failure(refusal) = result else { return }
        switch refusal {
        case let .lockBusy(line), let .journalUnreadable(line):
            audioWarning = line
        case .commandRunning:
            // Its line is `commandWarning`, which goes when the command exits.
            break
        }
        if !retrying { audioRetriesLeft = Self.audioRetryLimit }
        scheduleAudioRetry()
    }

    /// Whether a lid close may still be in effect, so a muted output must
    /// wait for the lid open: the lid is closed or its state unknown, and a
    /// session is running. Before the launch reconcile has taken a session
    /// over, or when it could not, that session is only on disk, so
    /// session.json is read here, under the transaction's lock. One that
    /// has not expired, or that cannot be read, counts as running.
    private func lidCloseMayBeInEffect() -> Bool {
        guard clamshell() != false else { return false }
        if session != nil { return true }
        do {
            guard let onDisk = try store.loadSession() else { return false }
            return !onDisk.isExpired(at: clock())
        } catch {
            return true
        }
    }

    /// Tries the saved output volumes again in `recoveryRetryDelay`, in
    /// process: the recovery agent keeps these entries but cannot restore
    /// them, and CoreAudio sends no second device event. One retry pending
    /// at a time. It reads the journal afresh and checks the lid again
    /// when it runs, and a restore that leaves nothing to retry cancels it.
    /// After `audioRetryLimit` retries in a row it stops; the entries stay
    /// for the next device change, lid open, end or launch.
    private func scheduleAudioRetry() {
        audioRetryTask?.cancel()
        audioRetryTask = nil
        guard audioRetriesLeft > 0 else {
            Log.error("audio: saved output volume still not checked or restored after \(Self.audioRetryLimit) retries; any saved volume stays in the journal, and the next device change, lid open, session end or launch tries again")
            return
        }
        audioRetriesLeft -= 1
        let delay = recoveryRetryDelay
        audioRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.audioRetryTask = nil
            Log.info("retrying the restore of saved output volume")
            await self.restoreOwedAudio("audio retry", retrying: true)
        }
    }

    /// The menu's "Stop waiting for <device>": the saved volume of an output
    /// device that is not connected leaves the journal, and the device
    /// stays muted until someone unmutes it. For a device that will not be
    /// back (a meeting room display, a borrowed speaker), whose entry would
    /// otherwise keep its menu line up for good and stop uninstall.sh. The
    /// menu item may be out of date by the time this runs, so both
    /// conditions are checked again under the lock, on the journal as it is
    /// on disk: the entry is still the save the item was built for, its
    /// save ID included, and the device still reads as not connected.
    /// Otherwise nothing is dropped. A later lid close's save stays, even
    /// one another copy of the app wrote with the same values, and a device
    /// that came back gets its volume as usual.
    func stopWaitingForOutput(_ waiting: SavedAudioOutput) async {
        let deviceUID = waiting.deviceUID
        _ = await exclusive("stop waiting for an output") {
            guard let entry = self.state.savedAudioOutputs.first(where: { $0.deviceUID == deviceUID }) else { return }
            guard entry == waiting else {
                Log.info("audio: stop waiting for \(entry.label) not done: the menu item was for an earlier save, already restored or dropped; the save from a later lid close stays")
                return
            }
            do {
                _ = try self.audio.read(deviceUID: deviceUID)
                self.audioDevicesNotConnected.remove(deviceUID)
                Log.info("audio: stop waiting for \(entry.label) not done: it is connected again, so its saved volume stays and is restored as usual")
                return
            } catch is AudioDeviceMissingError {
                // Still not connected: the request stands.
            } catch {
                self.fail("could not check whether \(entry.label) is connected: \(error.localizedDescription); its saved volume stays")
                return
            }
            do {
                try self.journal { $0.savedAudioOutputs.removeAll { $0.deviceUID == deviceUID } }
                self.audioDevicesNotConnected.remove(deviceUID)
                Log.info("audio: stopped waiting for \(entry.label) as asked; its saved volume \(entry.volume) and mute \(entry.muted) are dropped, and it stays muted")
            } catch {
                self.fail("could not drop the saved volume of \(entry.label): \(error.localizedDescription)")
            }
        }
    }

    /// Shared body of lid open, reconcile (lid open) and `restoreAll()`;
    /// each entry is journaled as soon as it is undone.
    private func undoLidActionsInJournal() {
        // Every error of this undo goes into one report at the end, so a
        // refused brightness restore, which recurs at every lid open and
        // launch, does not hide a failed resume, audio or write beside it.
        var errors: [String] = []
        let failsBefore = failCount
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
            clearUndone("Docker Desktop has no frozen process left") { $0.dockerFrozen = false }
        }

        if !state.savedAudioOutputs.isEmpty || state.savedOutputVolume != nil || state.savedMuted != nil {
            restoreAudioInJournal()
        }
        // The audio restore and a failed clear above put their own line in
        // the menu, where the report below would replace it: it goes into
        // the report. A line left by an earlier run does not.
        let shownAbove = failCount == failsBefore ? nil : lastError.flatMap { $0 == audioWarning || $0 == uncleared?.message ? $0 : nil }

        // Display and keyboard were darkened by us (spec section 4), not by
        // the OS: with the sleep guard on, macOS never turns the panel off on
        // lid close, so brightness 0 is what keeps it dark. Wake first: the
        // panel may also be asleep from the best-effort sleep request.
        // Brightness entries are read with the owed edits applied: an entry
        // this process already settled is not restored again.
        let kept = effectiveState
        if kept.brightnessJournaled {
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
        var refused: [String] = []
        var waiting: [String] = []
        if let saved = kept.savedDisplayBrightness, let why = display.refusal() {
            refused.append(keepRefusedRestore("Display brightness", saved: saved, why: why, flag: \.displayRestoreRefused))
        } else if let saved = kept.savedDisplayBrightness {
            restoredDisplay = restoreDisplay(saved: saved, waiting: &waiting, errors: &errors)
        }
        if let saved = kept.savedKeyboardBrightness, let why = keyboard.refusal() {
            refused.append(keepRefusedRestore("Keyboard backlight", saved: saved, why: why, flag: \.keyboardRestoreRefused))
        } else if let saved = kept.savedKeyboardBrightness {
            restoredKeyboard = restoreKeyboard(saved: saved, waiting: &waiting, errors: &errors)
        }
        waiting += owedEdits.clearsWaiting
        if !refused.isEmpty {
            let one = refused.count == 1
            errors.append("could not restore the brightness saved before the lid closed on this macOS build. \(refused.joined(separator: " ")) Set \(one ? "the level" : "the levels") with the brightness keys or Control Center; the saved \(one ? "value stays" : "values stay") in the journal for a version that can restore \(one ? "it" : "them")")
        }
        if !errors.isEmpty {
            fail(([shownAbove].compactMap { $0 } + errors).joined(separator: ". "))
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
    /// A level above 0 read under Insomnia's Low Power Mode, or after it
    /// in this run or boot (`keptDisplayReadDoubt`), may be the mode's
    /// rescaled value or one on its way back, not the user's: it would
    /// become the sampler's sample and so the level the next close
    /// journals. The entry waits, and is decided by a reading in a later
    /// boot. A reading of 0 still writes the kept value, owed once more
    /// after the mode as for any restore under it, unless that entry read
    /// above 0 since, in this run or an earlier one
    /// (`RuntimeState.keptDisplayReadLit`): that 0 may be the user's, or
    /// one macOS still holds the panel at, as auto-brightness can after a
    /// lid close, for a time nobody has measured. No reading of 0 tells
    /// the two apart, however late, so the entry waits with nothing
    /// written, and the sampler stays held, until the panel reads above 0.
    /// A 0 the user set stays as set, and so do the entry and its refusal
    /// message, until then.
    private func restoreDisplay(saved: Float, waiting: inout [String], errors: inout [String]) -> Float? {
        if effectiveState.displayRestoreRefused {
            switch keptLevel(read: { try display.readBrightness() },
                             untrusted: { display.isAsleep() ? "the display is asleep" : nil }) {
            case .undecided(let why):
                waiting.append("display brightness \(saved), kept after a refused restore, not read: \(why)")
                return nil
            case .setSince(let now):
                if let doubt = keptDisplayReadDoubt {
                    noteKeptDisplayReadLit(saved)
                    waiting.append("display brightness \(saved), kept after a refused restore, reads \(now) \(doubt); that is not taken as a level set since")
                    return nil
                }
                clearSetSince("display brightness", saved: saved, now: now, owed: \.display, errors: &errors) { s in
                    s.savedDisplayBrightness = nil
                    s.displayRestoreRefused = false
                }
                didSettleBrightness?(now, nil)
                return nil
            case .dark where effectiveState.keptDisplayReadLitHolds:
                if let doubt = keptDisplayReadDoubt {
                    waiting.append("display brightness \(saved), kept after a refused restore, reads 0 \(doubt), after a reading above 0 showed its darkening undone; that 0 may be a level set since, so the kept value is not written")
                } else {
                    waiting.append("display brightness \(saved), kept after a refused restore, reads 0 after a reading above 0 showed its darkening undone; that 0 may be a level set since or one macOS still holds the panel at after a lid close, and only a reading above 0 tells them apart, so the kept value is not written")
                }
                return nil
            case .dark:
                break
            }
        }
        do {
            try display.setBrightness(saved)
        } catch {
            errors.append("could not restore display brightness: \(error.localizedDescription)")
            makeRetryable("display brightness", saved: saved, flag: \.displayRestoreRefused, owed: \.display, errors: &errors)
            return nil
        }
        Log.info("display restored (brightness \(saved))")
        didSettleBrightness?(saved, nil)
        // Written under our Low Power Mode: written again once the
        // mode is off, since the mode's end rescales the panel. A mode
        // switched off whose clear is owed is off.
        let underLowPower = effectiveState.lowPowerSetByUs
        let clear: (inout RuntimeState) -> Void = { s in
            s.savedDisplayBrightness = nil
            s.displayRestoreRefused = false
            s.displayRestoredUnderLowPower = underLowPower ? saved : nil
        }
        do {
            try journal(clear)
        } catch {
            errors.append(unclearedLine("display brightness restored but the journal entry could not be cleared: \(error.localizedDescription); it will be retried", clear))
            settleRestored(saved, underLowPower: underLowPower, flag: \.displayRestoreRefused, owed: \.display)
        }
        return saved
    }

    /// As restoreDisplay, for the keyboard backlight.
    private func restoreKeyboard(saved: Float, waiting: inout [String], errors: inout [String]) -> Float? {
        if effectiveState.keyboardRestoreRefused {
            switch keptLevel(read: { try keyboard.readBrightness() },
                             untrusted: { keyboard.isSuppressedOrDimmed() ? "macOS has the backlight suppressed or dimmed" : nil }) {
            case .undecided(let why):
                waiting.append("keyboard backlight \(saved), kept after a refused restore, not read: \(why)")
                return nil
            case .setSince(let now):
                clearSetSince("keyboard backlight", saved: saved, now: now, owed: \.keyboard, errors: &errors) { s in
                    s.savedKeyboardBrightness = nil
                    s.keyboardRestoreRefused = false
                }
                didSettleBrightness?(nil, now)
                return nil
            case .dark:
                break
            }
        }
        do {
            try keyboard.setBrightness(saved)
        } catch {
            errors.append("could not restore keyboard backlight: \(error.localizedDescription)")
            makeRetryable("keyboard backlight", saved: saved, flag: \.keyboardRestoreRefused, owed: \.keyboard, errors: &errors)
            return nil
        }
        Log.info("keyboard backlight restored (brightness \(saved))")
        didSettleBrightness?(nil, saved)
        let clear: (inout RuntimeState) -> Void = { s in
            s.savedKeyboardBrightness = nil
            s.keyboardRestoreRefused = false
        }
        do {
            try journal(clear)
        } catch {
            errors.append(unclearedLine("keyboard backlight restored but the journal entry could not be cleared: \(error.localizedDescription); it will be retried", clear))
            settleRestored(saved, flag: \.keyboardRestoreRefused, owed: \.keyboard)
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
            let result = await self.exclusive("brightness re-check") { await self.recheckKeptBrightness() }
            switch result {
            case .failure(.lockBusy), .failure(.commandRunning):
                // Another holder of the lock, or a power command left
                // running, skips one read, not the ones after it.
                if !Task.isCancelled { self.scheduleKeptRecheck(after: self.keptRecheckSlowDelay) }
            case .success, .failure(.journalUnreadable):
                break
            }
        }
    }

    /// Only the kept values the guard allows: the rest of the journal is
    /// for a lid open, an end or the backstop. Only with the lid known to
    /// be open, as reconcile undoes lid actions: under a closed lid a write
    /// would light what the close keeps dark. Until the lid is known open
    /// nothing is read, at the slow pace, and the first reading after that
    /// starts a new count, since the wake holds the backlight down again.
    /// A clear still owed keeps it going too: the transaction is what
    /// tries the journal again (see `owedEdits`).
    private func recheckKeptBrightness() async {
        let kept = effectiveState
        let rereadDisplay = kept.savedDisplayBrightness != nil && kept.displayRestoreRefused && display.refusal() == nil
        let rereadKeyboard = kept.savedKeyboardBrightness != nil && kept.keyboardRestoreRefused && keyboard.refusal() == nil
        guard rereadDisplay || rereadKeyboard || !owedEdits.clearsWaiting.isEmpty else { return }
        guard clamshell() == false || !(rereadDisplay || rereadKeyboard) else {
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
        if rereadDisplay, let saved = kept.savedDisplayBrightness {
            restoredDisplay = restoreDisplay(saved: saved, waiting: &waiting, errors: &errors)
        }
        if rereadKeyboard, let saved = kept.savedKeyboardBrightness {
            restoredKeyboard = restoreKeyboard(saved: saved, waiting: &waiting, errors: &errors)
        }
        waiting += owedEdits.clearsWaiting
        if !errors.isEmpty {
            fail(errors.joined(separator: ". "))
        }
        scheduleReassert(display: restoredDisplay, keyboard: restoredKeyboard)
        // A write that failed here makes the entry an ordinary failed
        // restore. With no session, no lid open or end would come for it,
        // so it is ended now as for any dirty journal: handed to the agent,
        // or retried by this process while the disk hides it from the agent.
        if session == nil, journalNeedsRestore(leavingOutAudioOf: Set(state.savedAudioOutputs.map(\.deviceUID))) {
            Log.info("brightness re-check: a kept value failed to restore; ending as for a dirty journal")
            _ = await performEnd(reason: .backstop)
            return
        }
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
        let journaled = effectiveState
        guard let value = journaled.displayRestoredUnderLowPower, !journaled.lowPowerSetByUs else { return }
        guard journaled.savedDisplayBrightness == nil else {
            dropDisplayWrite(reason: "darkened again")
            return
        }
        do {
            try display.setBrightness(value)
            Log.info("display restored again after low power mode (brightness \(value))")
            didSettleBrightness?(value, nil)
            clearDisplayWriteAfterLowPower()
            scheduleReassert(display: value, keyboard: nil)
        } catch {
            Log.error("display restore after low power mode failed: \(error.localizedDescription)")
            clearDisplayWriteAfterLowPower()
        }
    }

    /// Before the mode is switched off: if the panel no longer reads what
    /// was written under it (beyond auto-brightness drift), the user has
    /// moved it since the lid opened, and the second write would undo
    /// that. The panel is theirs; nothing is owed.
    private func dropDisplayWriteIfMoved() {
        let journaled = effectiveState
        guard let value = journaled.displayRestoredUnderLowPower, journaled.savedDisplayBrightness == nil else { return }
        guard let now = try? display.readBrightness() else { return }
        if abs(now - value) > Self.untouchedDisplayTolerance {
            dropDisplayWrite(reason: "the display moved since the restore (\(now), restored \(value))")
        }
    }

    private func dropDisplayWrite(reason: String) {
        guard effectiveState.displayRestoredUnderLowPower != nil else { return }
        Log.info("display restore after low power mode dropped: \(reason)")
        clearDisplayWriteAfterLowPower()
        // The open's own second write of that value, if still pending,
        // would land it all the same.
        pendingReassert.display = nil
    }

    /// The display write owed after Low Power Mode, done or dropped, off
    /// the journal. If the journal refuses, the clear is owed (see
    /// `owedEdits`), so no later write puts the value back: neither one
    /// that succeeds with the entry still on disk, nor a restore owed
    /// under the mode, whose own write after the mode is taken out too. A
    /// restore owed after this one keeps its write.
    private func clearDisplayWriteAfterLowPower() {
        do {
            try journal { $0.displayRestoredUnderLowPower = nil }
        } catch {
            owedEdits.displayWriteAfterLowPowerCleared = true
            if case let .restored(value, true)? = owedEdits.display {
                owedEdits.display = .restored(value, underLowPower: false)
            }
            Log.error("could not clear the display write owed after low power mode from the journal: \(error.localizedDescription); it is not made, and the next journal write or transaction clears it")
        }
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
                // With the owed edits applied: a restore whose clear the
                // journal has not taken yet is done all the same.
                let journaled = self.effectiveState
                if let value = restoredDisplay {
                    if journaled.savedDisplayBrightness != nil {
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
                    if journaled.savedKeyboardBrightness != nil {
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
        announceLidCloseUpdate()
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

    /// Posts the lid-close update's notification once, before the
    /// transaction, so a busy lock or an unreadable journal cannot hold it
    /// back. Not from init: the app builds the manager before it installs
    /// its notification delegate (`ForegroundNotifications`), which is what
    /// shows a notification while Insomnia is the active app, and the
    /// launch reconcile runs after that.
    private func announceLidCloseUpdate() {
        guard let change = pendingLidCloseNotice else { return }
        pendingLidCloseNotice = nil
        notifier.post(title: LidCloseDefaultsChange.title, body: change.notificationBody)
    }

    /// Settings' Dismiss on the lid-close update line. Saved to config.json,
    /// whose mark keeps the update from running again, so the line stays
    /// gone after a relaunch. A failed save leaves it dismissed for this run.
    func dismissLidCloseNotice() {
        guard config.lidCloseDefaultsNotice != nil else { return }
        config.lidCloseDefaultsNotice = nil
        do {
            try store.saveConfig(config)
        } catch {
            Log.error("could not save config: \(error.localizedDescription)")
        }
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

        // A start whose settlement is published, but whose claim could not
        // be given back or record removed since (`settleSleepOffAttempt`
        // tried again above). The record names the session it leaves to be
        // resumed (`SleepOffAttempt.resumes`): that start's own when it
        // turned sleep off, the one from before it that its rollback put
        // back, or the one its settlement left in place. That session, and
        // only that one, is resumed below like any other, under the same
        // checks (not expired, sleep still off); the record names it before
        // the claim goes back, so a crash at any point leaves either the
        // record unsettled with its claim or the name. A record without the
        // name (an older build's, or one the scripts settled after
        // removing the start's own session) resumes the session whose first
        // end is the start's deadline, with the sleep entry still journaled
        // (`isSession`). The record stays, Starts are refused until it goes,
        // and every transaction and agent run tries again; the decision is
        // never read against the receipt again.
        let settledResumes = onDisk.map { s in
            state.sleepOffAttempt.map { Self.isResumed(s, by: $0, sleepEntry: state.sleepDisabledByUs) } ?? false
        } ?? false
        if let s = onDisk, !s.isExpired(at: now), (state.sleepOffAttempt != nil && !settledResumes) || unrecordedMarkerSession {
            // A start the journal still records could not be settled: its
            // dialog can still be answered, its receipt stayed locked or
            // could not be read, or a removal or the journal write failed.
            // Or its settlement is published, the session is not the one
            // it leaves to be resumed, and its claim could not be given back
            // or its record removed: the safe side, and only after a crash
            // with that left over.
            // Or the session.json beside a marker no journaled start
            // accounts for could not be removed. Whether that start turned
            // sleep off is not settled, so a SleepDisabled 1 now may be
            // someone else's, and the session it wrote is never resumed on
            // it. It ends like any session; the restore runs unless the
            // settlement holds it back (`attemptHold`), and the entry stays
            // with the record until a settlement removes it (restoreAll).
            unrecordedMarkerSession = false
            Log.info("reconcile: session.json until \(iso(s.endsAt)) belongs to a start that is not settled; ending it instead of resuming it")
            _ = await performEnd(reason: .startFailed)
            return
        }
        if let s = onDisk, !s.isExpired(at: now) {
            // Step 2: valid session. Arm first, then check that sleep is
            // still off, then journal. Any failure ends the session rather
            // than holding sleep with nothing guaranteed to release it.
            session = s
            do {
                try await backstop.arm()
            } catch {
                fail("could not arm recovery agent for the session on disk: \(error.localizedDescription); ending it")
                _ = await performEnd(reason: .recoveryUnavailable)
                return
            }
            // Never re-applied: `disablesleep 1` needs the administrator
            // password, and a relaunch (login, a crash) has nobody at the
            // keyboard to type it. The session continues only if sleep is
            // still off; if it was turned back on meanwhile the session ends
            // and says so.
            let sleepStillOff: Bool
            do {
                sleepStillOff = try await sleepGuard.isSleepDisabled()
            } catch {
                fail("could not read the sleep setting for the session on disk: \(error.localizedDescription); ending it")
                _ = await performEnd(reason: .recoveryUnavailable)
                return
            }
            guard sleepStillOff else {
                Log.info("reconcile: sleep was turned back on while Insomnia was not running; ending the session")
                _ = await performEnd(reason: .sleepReenabled)
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
            clearLastError()
            Log.info("reconcile: session valid until \(iso(s.endsAt))")
            if settledResumes {
                Log.info("reconcile: this session's start is still recorded (\(attemptProblem ?? "it is settled")); starts are refused until a later run gives its claim back and removes the record")
            }
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
        // A session.json kept in place is renamed by an end, which is
        // retried until it moves, so saved output volumes alone then call
        // for one too, as on any other dirty journal.
        let savedOutputs = Set(state.savedAudioOutputs.map(\.deviceUID))
        let owesEnd = keptSessionFile != nil ? state.isDirty : state.isDirty(leavingOutAudioOf: savedOutputs)
        if onDisk != nil {
            Log.info("reconcile: session expired, restoring")
            if case .privilegedCommandRunning = await performEnd(reason: .timer) { return }
        } else if owesEnd {
            Log.info(keptSessionFile != nil
                ? "reconcile: session.json kept in place, restoring the journal as for an expired session"
                : "reconcile: no session but dirty state, restoring")
            if case .privilegedCommandRunning = await performEnd(reason: .backstop) { return }
        } else {
            // Only output volumes are owed, from an end that found their
            // devices not connected, or a brightness kept after a refused
            // restore, which is not dirty. No session to end and nothing to
            // announce on every launch: each device is tried, and one still
            // not connected keeps its entry and its menu line.
            let refusedKept = state.hasRefusedBrightness
            if state.displayRestoredUnderLowPower != nil {
                dropDisplayWrite(reason: "no session and the mode is not ours")
            } else if savedOutputs.isEmpty, !refusedKept {
                Log.info("reconcile: no session, nothing to restore")
            }
            if refusedKept {
                // This launch may be the build or macOS that can make the
                // call; still refused, the entry stays. The undo restores
                // the saved output volumes too.
                Log.info("reconcile: no session; trying again the brightness kept after a refused restore")
                undoLidActionsInJournal()
                // A write that failed made the entry an ordinary failed
                // restore: ended as for any dirty journal, so the agent is
                // armed for it, or this process retries it while the disk
                // still hides it from the agent.
                if journalNeedsRestore(leavingOutAudioOf: savedOutputs) {
                    Log.info("reconcile: a kept brightness failed to restore; ending as for a dirty journal")
                    if case .privilegedCommandRunning = await performEnd(reason: .backstop) { return }
                }
            } else if !savedOutputs.isEmpty {
                Log.info("reconcile: no session; restoring the volume saved for \(savedOutputs.count) output device(s)")
                restoreAudioInJournal()
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
    /// launch. Start is refused while the bit reads 1 (see
    /// `checkSleepSettingForStart`), so the line is cleared by a recheck
    /// that reads it as 0, or by a session start that found it 0.
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
            body: "pmset reports SleepDisabled 1, but Insomnia has no session and did not set it, so it is left alone. To re-enable sleep: \(Self.foreignSleepCommand). Insomnia cannot start a session until then."
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
        restoreSessionFile(previous)
    }

    /// Puts session.json back as it was before a start: `previous`, or no
    /// file.
    private func restoreSessionFile(_ previous: Session?) {
        do {
            try putBackSessionFile(previous)
        } catch {
            fail("could not restore session.json after a failed start: \(error.localizedDescription)")
        }
    }

    private func putBackSessionFile(_ previous: Session?) throws {
        if let previous {
            try store.saveSession(previous)
        } else {
            try store.deleteSession()
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
        if claimsLowPowerInThisBoot(s) { lowPowerWasOurs = true }
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
        failCount += 1
        Log.error(message)
    }

    /// Posted once per stuck prompt: the notification and the menu's
    /// warning line say what is running and what Insomnia does about it.
    /// `kill <pid>` is only offered while the pid is osascript's own, and
    /// only on the menu line: that line is replaced as soon as osascript
    /// exits, while a notification stays in Notification Center after the
    /// pid is gone and possibly reused.
    private func reportStuckPrompt(_ prompt: UnfinishedPrompt, grace: TimeInterval, osascriptAlive: Bool, voided: Bool) {
        let body = Self.stuckPromptText(prompt, grace: grace, osascriptAlive: osascriptAlive, voided: voided)
        if osascriptAlive {
            fail("start: \(body) To stop it by hand while it runs: kill \(prompt.pid)")
            notifier.post(title: Self.promptStuckTitle, body: "\(body) The Insomnia menu shows how to stop it while it runs.")
        } else {
            fail("start: \(body)")
            notifier.post(title: Self.promptStuckTitle, body: body)
        }
    }

    private static func stuckPromptText(_ prompt: UnfinishedPrompt, grace: TimeInterval, osascriptAlive: Bool, voided: Bool) -> String {
        let what = osascriptAlive
            ? "osascript (pid \(prompt.pid)), the process behind the password dialog, did not stop within \(Int(grace)) s."
            : "osascript (pid \(prompt.pid)) stopped, but a command it started as root is still running."
        if voided {
            return "\(what) Its start's marker is gone, so a command it starts from now on stops at that check, and any command for that start refuses once the start's answer window has ended. Insomnia then settles the start from the receipt once it can lock it; while a command for the start holds that lock, the start stays unsettled, Starts are refused and sleep is left as it is."
        }
        return "\(what) Insomnia keeps the session record and waits for it before rolling the start back; nothing else runs until then."
    }

    /// Outside any transaction, keeps the menu line `reportStuckPrompt`
    /// set for a voided prompt true until the prompt is gone: the kill hint
    /// goes when osascript exits, the whole line when the prompt has
    /// exited. A line something else has set since is left alone.
    private func watchVoidedPrompt(_ prompt: UnfinishedPrompt, grace: TimeInterval) {
        let reported = lastError
        Task { @MainActor [weak self] in
            var line = reported
            await prompt.waitUntilOsascriptExits()
            if let self, line != nil, self.lastError == line, prompt.isRunning {
                line = "start: \(Self.stuckPromptText(prompt, grace: grace, osascriptAlive: false, voided: true))"
                self.lastError = line
            }
            await prompt.waitUntilExit()
            if let self, line != nil, self.lastError == line { self.lastError = nil }
            Log.info("\(prompt), whose start was voided, has exited")
        }
    }

    /// What clearing the pending-start marker found.
    enum MarkerClearing: Equatable {
        /// The marker is still there (see clearPendingStart).
        case kept
        /// The marker is gone. `file` is the file that was locked and
        /// deleted; nil when there was nothing, or a link to nothing.
        case cleared(file: FileIdentity?)
    }

    /// Locks, then deletes the pending-start marker (see PendingStart and
    /// `Store.removePendingStart`), and records the outcome in
    /// `markerProblem`. `.kept` when the root command behind a dialog still
    /// held the marker's lock after `markerLockTimeout`, or the file could
    /// not be deleted (an immutable flag, a deny-delete ACL, a directory in
    /// its place), or, with `expecting`, the file at the path is not the
    /// one this start wrote. The failure is logged and shown in the menu,
    /// and every later transaction, backstop run and uninstall tries again.
    @discardableResult
    private func clearPendingStart(expecting written: FileIdentity? = nil) async -> MarkerClearing {
        let removed: RemovedMarker?
        do {
            removed = try await store.removePendingStart(timeout: markerLockTimeout, expecting: written)
            if removed != nil {
                Log.info("deleted the pending-start marker; a command a password dialog left from that start runs stops at its marker check from now on, unless this user writes the marker again or the clock is set back")
            }
            if let old = markerProblem {
                markerProblem = nil
                if lastError == Self.markerProblemText(old) { lastError = nil }
            }
        } catch {
            markerProblem = error.localizedDescription
            fail(Self.markerProblemText(error.localizedDescription))
            return .kept
        }
        return .cleared(file: removed?.file)
    }

    /// Whole seconds since 1970, rounded down, as the journal and
    /// session.json hold times. For this Mac's clock only: times read from
    /// disk are compared as Doubles (`isSession`), so nothing there can
    /// trap the conversion.
    private static func seconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded(.down)) }

    /// Whether `s` is the session `attempt`'s start wrote: it began at
    /// least `SessionMath.minimumDuration` before the start's deadline, and
    /// its first end, before any extension (`SessionMath.firstEnd`), is
    /// that deadline. The deadline is the first end rounded down to the
    /// second, as session.json keeps every time, while it keeps each
    /// extension to a fraction of a second. With whole-second extensions
    /// the first end comes out exactly. An extension with a fraction (one
    /// cut short at the maximum) leaves an end with a fraction, which each
    /// save drops from the end but not from the extensions, and a relaunch
    /// extends from the end without it. So each such extension can put
    /// the first end that comes out up to a second earlier, and the
    /// fraction the start's own end had, up to a second later: with `n` of
    /// them it is after `deadline - n` and before `deadline + 1`. Outside
    /// that, or with a history no session this app wrote has, the session
    /// is not the start's own, and reconcile ends it as before. Everything
    /// here compares Doubles, so no journal or session.json value can trap
    /// a conversion or overflow a subtraction.
    /// A session whose id (`Session.id`) is not the one the start
    /// journaled (`SleepOffAttempt.session`) is not the start's own,
    /// whatever its times; with no id on either side the times decide.
    static func isSession(_ s: Session, of attempt: SleepOffAttempt) -> Bool {
        if s.sameID(as: attempt.session) == false { return false }
        let started = s.startedAt.timeIntervalSince1970.rounded(.down)
        guard started + SessionMath.minimumDuration <= Double(attempt.deadline) else { return false }
        return hasFirstEnd(s, attempt.deadline)
    }

    /// Whether `s`'s first end comes out as `end`, within the window
    /// `isSession` describes for extensions with a fraction of a second.
    private static func hasFirstEnd(_ s: Session, _ end: Int) -> Bool {
        guard let first = SessionMath.firstEnd(of: s) else { return false }
        let deadline = Double(end)
        let fractions = s.extensions.filter { $0 != $0.rounded(.down) }.count
        if fractions == 0 { return first.rounded(.down) == deadline }
        // A thousandth of a second for the rounding of the sums above.
        let slack = 0.001
        return first > deadline - Double(fractions) - slack && first < deadline + 1 + slack
    }

    /// Whether `s` is the session the settled `attempt` leaves to be
    /// resumed (`SleepOffAttempt.resumes`): the same `startedAt`, to the
    /// second, and the same first end, within `isSession`'s window. That
    /// is what session.json keeps of a session, not proof that it is the
    /// same one: a session written in that same second with that first end
    /// passes too, unless both carry an id (`Session.id`, round 36), which
    /// must then be the same. A session or record of an older build has
    /// none, and the times alone decide. Without `resumes` (a record
    /// settled by an older build or by the scripts), the first end alone
    /// decides, as `isSession`, with the sleep entry journaled. `.none`
    /// matches no session.
    static func isResumed(_ s: Session, by attempt: SleepOffAttempt, sleepEntry: Bool) -> Bool {
        guard attempt.isSettled else { return false }
        guard let resumes = attempt.resumes else { return sleepEntry && isSession(s, of: attempt) }
        guard let started = resumes.startedAt, let end = resumes.firstEnd else { return false }
        if s.sameID(as: resumes.id) == false { return false }
        return s.startedAt.timeIntervalSince1970.rounded(.down) == Double(started) && hasFirstEnd(s, end)
    }

    /// The receipt's lock (`SleepOffReceipts.lock`), or the error it threw.
    private func lockReceipt() async -> Result<SleepOffReceipts.Guard, Error> {
        do {
            return .success(try await receipts.lock(timeout: receiptLockTimeout))
        } catch {
            return .failure(error)
        }
    }

    /// Records why the start the journal still records stays there:
    /// `attemptProblem`, which a new start is refused with, and
    /// `attemptHold` when no sleep undo may run for it. Undecided holds the
    /// undo whatever the time and whatever an earlier session owes: the
    /// receipt stays locked or cannot be locked, or the dialog can still
    /// be answered, so a command for that start may still act, and a pmset
    /// it already started can turn sleep off after the undo. The start's
    /// `expires` only stops commands that have not begun. The undo is held
    /// too when the receipt shows its command never turned sleep off and no
    /// earlier restore is owed: a SleepDisabled 1 now may be another
    /// tool's. A start that may have written, or one that never wrote
    /// behind a restore an earlier session owes, runs the undo and keeps
    /// the entry with the record (`restoreAll`). The restore an earlier
    /// session owes stays journaled while it is held, and runs once the
    /// start is settled.
    private func keepAttempt(_ attempt: SleepOffAttempt, _ verdict: SleepOffVerdict, because why: String) {
        attemptProblem = why
        switch verdict {
        case .neverWrote:
            attemptHold = attempt.owedBefore ? nil : "the receipt shows that the command behind that start's dialog never turned sleep off and no earlier restore is owed, but \(why)"
        case .mayHaveWritten:
            attemptHold = nil
        case .undecided:
            attemptHold = why
        }
    }

    /// A settlement published its decision but could not give the claim
    /// back or remove the record (`SettlementPublication.pending`). The
    /// settled record adds nothing to undo and holds nothing back; it only
    /// refuses new starts until a later run finishes it.
    private func settlementPending(_ why: String) {
        attemptProblem = "it is settled, but \(why)"
        attemptHold = nil
    }

    /// How far `publishSettlement` got.
    private enum SettlementPublication {
        /// Published, the claim given back and the record removed.
        case done
        /// Nothing was written: the record stays unsettled, the claim
        /// held, and the receipt's line still shows the same thing next
        /// time. The reason.
        case notPublished(String)
        /// The decision is in the journal (`SleepOffAttempt.settled`), but
        /// the claim could not be given back or the settled record could
        /// not be removed. The next transaction, backstop.sh or
        /// uninstall.sh finishes it without reading the receipt again. The
        /// reason.
        case pending(String)
    }

    /// Under `held`: runs `write`, which journals the decision with
    /// `attempt` marked settled and naming the session it leaves to be
    /// resumed (`resumes`), then gives the claim back and removes the
    /// record (`finishSettlement`). The claim stays held until the
    /// decision is on disk, so no start from another Insomnia folder can
    /// add receipt lines that would make the receipt show something else
    /// before the decision is kept: a crash or a failure at any point
    /// leaves either the record unsettled with its claim, or the decision.
    private func publishSettlement(of attempt: SleepOffAttempt, resumes: ResumedSession, under held: SleepOffReceipts.Guard, _ write: (SleepOffAttempt) throws -> Void) -> SettlementPublication {
        var settled = attempt
        settled.settled = true
        settled.resumes = resumes
        do {
            try write(settled)
        } catch {
            return .notPublished("the journal could not be updated (\(error.localizedDescription))")
        }
        return finishSettlement(of: settled, under: held)
    }

    /// Under `held`: gives a settled record's claim back, when the release
    /// file still shows it held, then removes the record.
    private func finishSettlement(of attempt: SleepOffAttempt, under held: SleepOffReceipts.Guard) -> SettlementPublication {
        do {
            try receipts.release(attempt.nonce, under: held)
        } catch {
            return .pending("its claim on the receipt could not be given back (\(error.localizedDescription))")
        }
        do {
            try journal { $0.sleepOffAttempt = nil }
        } catch {
            return .pending("its settled record could not be removed from the journal (\(error.localizedDescription))")
        }
        return .done
    }

    /// With no session in memory, deletes session.json when it is the one
    /// `attempt` wrote (its end is the start's deadline, and its id, when
    /// both have one, the start's session id): that session
    /// never began, and it must go before the settlement is published so
    /// it is never resumed because a SleepDisabled 1 someone else set reads
    /// as still off. Returns whether it deleted it.
    private func removeSessionOfUnfinishedStart(_ attempt: SleepOffAttempt) throws -> Bool {
        guard session == nil, let s = try? store.loadSession(), s.endsAt.timeIntervalSince1970.rounded(.down) == Double(attempt.deadline), s.sameID(as: attempt.session) != false else { return false }
        try store.deleteSession()
        Log.info("removed session.json of a start that never finished")
        return true
    }

    /// The session a settlement of a start leaves to be resumed
    /// (`SleepOffAttempt.resumes`): the one in memory, else session.json as
    /// it is now, else none. A session.json whose bytes are not a session
    /// names none, since nothing in it could be resumed. One that cannot
    /// be read at all throws: the settlement is not published, its record
    /// stays unsettled with its claim, and the next transaction reads it
    /// again, after reconcile moved it aside.
    private func sessionLeftToResume() throws -> ResumedSession {
        if let session { return ResumedSession(session) }
        do {
            return try store.loadSession().map(ResumedSession.init) ?? .none
        } catch StoreError.unreadable(_, _) {
            return .none
        }
    }

    /// Settles the start the journal still records (`sleepOffAttempt`)
    /// from its receipt, under the receipt's lock: this process crashed or
    /// was force-quit while the start ran, or an earlier settlement could
    /// not finish, and neither backstop.sh nor uninstall.sh has settled it
    /// since. Runs at the top of every transaction, whatever happened to
    /// the marker.
    ///
    /// A record already settled is only finished (`finishSettledAttempt`).
    /// Undecided (`SleepOffVerdict.undecided`: its dialog can still be
    /// answered, or the receipt stays locked or cannot be locked) keeps
    /// everything, the record, the entry, session.json and the claim, holds
    /// the sleep undo (`keepAttempt`), and the next transaction reads the
    /// receipt again. Otherwise that start never finished, so its session
    /// never began: its session.json goes first
    /// (`removeSessionOfUnfinishedStart`). Then the journal records the
    /// decision with the record marked settled: the sleep entry from before
    /// the start when no command for it turned sleep off, which keeps a
    /// restore an earlier session still owes, and the entry kept
    /// otherwise, so the restore runs like any other, and the session left
    /// is named as the one to resume (`sessionLeftToResume`). Only then
    /// does the claim go back and the record go. A removal, read or write
    /// that fails before the decision is published keeps the record
    /// unsettled with its claim, so the receipt's line still shows the
    /// same thing next time:
    /// reconcile ends an unexpired session rather than resume it, starts
    /// are refused, the menu says what was removed, and the next
    /// transaction tries again.
    ///
    /// A start this process rolled back as one that never turned sleep off
    /// but could not journal (`refusedNonce`) is settled that way whatever
    /// its receipt shows.
    private func settleSleepOffAttempt() async {
        attemptProblem = nil
        attemptHold = nil
        guard let attempt = state.sleepOffAttempt else { return }
        if attempt.isSettled {
            refusedNonce = nil
            await finishSettledAttempt(attempt)
            return
        }
        let received = refusedNonce == attempt.nonce
        if !received { refusedNonce = nil }
        let outcome = await lockReceipt()
        defer { if case let .success(held) = outcome { held.release() } }
        let now = Self.seconds(clock())
        var verdict = receipts.verdict(for: attempt, lock: outcome, now: now)
        if received {
            switch verdict {
            case .neverWrote:
                break
            case let .mayHaveWritten(shown), let .undecided(shown):
                Log.info("an earlier start's receipt alone does not settle it as one that never turned sleep off (\(shown)), but this process rolled it back as one whose command never turned sleep off; it is settled that way")
                verdict = .neverWrote
            }
        }
        let held: SleepOffReceipts.Guard
        switch (verdict, outcome) {
        case let (.undecided(why), _):
            keepAttempt(attempt, verdict, because: why)
            Log.info("an earlier start is not settled yet: \(why)")
            return
        case let (_, .failure(error)):
            let why = "the receipt could not be locked to give that start's claim back (\(error.localizedDescription))"
            keepAttempt(attempt, verdict, because: why)
            fail("could not settle an earlier start: \(why). Nothing was removed; starts are refused, and every run tries again")
            return
        case let (_, .success(g)):
            held = g
        }
        var removed = ""
        do {
            if try removeSessionOfUnfinishedStart(attempt) { removed = "; session.json of that start was removed" }
        } catch {
            let why = "session.json of that start could not be removed (\(error.localizedDescription))"
            keepAttempt(attempt, verdict, because: why)
            fail("could not settle an earlier start: \(why). Nothing was removed; its session is ended rather than resumed, starts are refused, and every run tries again")
            return
        }
        let resumes: ResumedSession
        do {
            resumes = try sessionLeftToResume()
        } catch {
            let why = "session.json could not be read to name the session this settlement leaves (\(error.localizedDescription))"
            keepAttempt(attempt, verdict, because: why + removed)
            fail("could not settle an earlier start: \(why)\(removed). The start stays recorded, starts are refused, and every run tries again")
            return
        }
        let owes = verdict == .neverWrote ? attempt.owedBefore : true
        let published = publishSettlement(of: attempt, resumes: resumes, under: held) { settled in
            var s = state
            s.sleepOffAttempt = settled
            s.sleepDisabledByUs = owes
            try persistState(s)
        }
        if case let .notPublished(why) = published {
            keepAttempt(attempt, verdict, because: why + removed)
            fail("could not settle an earlier start: \(why)\(removed). The start stays recorded, starts are refused, and every run tries again")
            return
        }
        refusedNonce = nil
        switch verdict {
        case .neverWrote:
            Log.info("settled an earlier start: \(received ? "this process rolled it back as one whose command never turned sleep off" : "its receipt shows the command behind its dialog never turned sleep off"); the sleep entry is back to \(attempt.owedBefore ? "owed by an earlier session" : "clear")")
        case let .mayHaveWritten(reason), let .undecided(reason):
            Log.info("settled an earlier start as one that may have turned sleep off (\(reason)); the sleep entry stays")
        }
        if case let .pending(why) = published {
            settlementPending(why)
            fail("settled an earlier start, but \(why)\(removed). Its record stays in the journal, marked settled, starts are refused, and every run tries again")
        }
    }

    /// Finishes a settlement whose decision is already in the journal:
    /// under the receipt's lock, the claim goes back and the record goes.
    /// The receipt is not read again. Once the claim went back, later
    /// starts' lines may make it show something else, so only the
    /// published decision counts.
    private func finishSettledAttempt(_ attempt: SleepOffAttempt) async {
        let held: SleepOffReceipts.Guard
        switch await lockReceipt() {
        case let .success(g):
            held = g
        case let .failure(error):
            let why = "the receipt could not be locked to give its claim back (\(error.localizedDescription))"
            settlementPending(why)
            if error is SleepOffReceipts.Busy {
                Log.info("an earlier start is settled, but \(why)")
            } else {
                fail("an earlier start is settled, but \(why). Its record stays in the journal, starts are refused, and every run tries again")
            }
            return
        }
        defer { held.release() }
        if case let .pending(why) = finishSettlement(of: attempt, under: held) {
            settlementPending(why)
            fail("an earlier start is settled, but \(why). Its record stays in the journal, starts are refused, and every run tries again")
            return
        }
        Log.info("finished an earlier start's settlement: its claim on the receipt was given back and its record removed")
    }

    /// After sleep was turned off for `attempt`: under the receipt's lock,
    /// marks the record settled, naming `new` as the session to resume,
    /// gives the claim back and drops the record, keeping the sleep entry.
    /// A lock or write that fails before the record is marked leaves it
    /// unsettled with its claim for the next transaction, whose settlement
    /// finds this start's `writing` and keeps the entry. One that fails
    /// after leaves the settled record for the next transaction to finish.
    private func finishAttempt(_ attempt: SleepOffAttempt, resuming new: Session) async {
        let held: SleepOffReceipts.Guard
        switch await lockReceipt() {
        case let .success(g):
            held = g
        case let .failure(error):
            attemptProblem = "the receipt could not be locked to give this start's claim back (\(error.localizedDescription))"
            Log.error("could not lock the receipt to give the start's claim back (\(error.localizedDescription)); the next run settles the start and keeps the sleep entry")
            return
        }
        defer { held.release() }
        switch publishSettlement(of: attempt, resumes: ResumedSession(new), under: held, { settled in try journal { $0.sleepOffAttempt = settled } }) {
        case .done:
            break
        case let .notPublished(why):
            attemptProblem = why
            Log.error("could not clear the start's record: \(why); the next run settles it and keeps the sleep entry")
        case let .pending(why):
            settlementPending(why)
            Log.error("the start's record is settled, but \(why); the next run finishes it")
        }
    }

    /// Rolls back a start whose command cannot have turned sleep off: no
    /// dialog was shown, or it ended with nothing to undo
    /// (`AdministratorPromptError.nothingToUndo`), or the receipt showed
    /// that it never turned sleep off. session.json goes back
    /// first, then under the receipt's lock the journal goes back exactly
    /// as it was, with the record marked settled and naming `previous` as
    /// the session to resume, and only then does the claim go back and the
    /// record go. A relaunch with that record left over resumes `previous`
    /// as it would without the record, and nothing else. Returns whether
    /// the journal and session.json went back. A session.json, lock or
    /// journal write that fails keeps the record unsettled with its claim,
    /// so the next settlement finishes the rest; no pmset runs for it unless an
    /// earlier restore is owed (`attemptHold`), and starts are refused
    /// until then. That settlement, in this process, settles it as one
    /// that never turned sleep off whatever the receipt shows
    /// (`refusedNonce`); one by a relaunch, backstop.sh or uninstall.sh
    /// reads the receipt alone. A claim or record removal that fails after
    /// that leaves the settled record for the next run to finish.
    @discardableResult
    private func abandonStart(_ attempt: SleepOffAttempt, journal before: RuntimeState, session previous: Session?) async -> Bool {
        attemptProblem = nil
        attemptHold = nil
        let why: String
        do {
            try putBackSessionFile(previous)
        } catch {
            why = "session.json could not be put back as it was (\(error.localizedDescription))"
            keepAttempt(attempt, .neverWrote, because: why)
            refusedNonce = attempt.nonce
            fail("the failed start stays recorded in the journal: \(why). No pmset runs for it\(attempt.owedBefore ? " beyond the restore an earlier session owes" : ""), its session is ended rather than resumed, starts are refused, and every run tries again")
            return false
        }
        switch await lockReceipt() {
        case let .success(held):
            defer { held.release() }
            let published = publishSettlement(of: attempt, resumes: previous.map(ResumedSession.init) ?? .none, under: held) { settled in
                var s = before
                s.sleepOffAttempt = settled
                try persistState(s)
            }
            switch published {
            case .done:
                return true
            case let .pending(failed):
                settlementPending(failed)
                fail("the failed start was rolled back, but \(failed). Its record stays in the journal, marked settled, starts are refused, and every run tries again")
                return true
            case let .notPublished(failed):
                why = failed
            }
        case let .failure(error):
            why = "the receipt could not be locked to give this start's claim back (\(error.localizedDescription))"
        }
        keepAttempt(attempt, .neverWrote, because: why)
        refusedNonce = attempt.nonce
        fail("the failed start stays recorded in the journal: \(why). session.json was put back as it was. No pmset runs for it\(attempt.owedBefore ? " beyond the restore an earlier session owes" : ""), starts are refused, and every run tries again")
        return false
    }

    /// A pending-start marker went that no journaled start accounts for:
    /// one left by a build from before `sleepOffAttempt`, or by a start
    /// that finished or rolled back but could not delete it. Whether a
    /// command behind its dialog turned sleep off is unknown, so with no
    /// session in memory, session.json beside it is never resumed: it goes.
    /// A sleep entry still journaled is restored like any other, and a
    /// SleepDisabled 1 the journal does not own is left alone. A session
    /// that had started and lost its marker only to a failed delete ends
    /// early here, which is the safe side. A removal that fails makes
    /// reconcile end that session rather than resume it.
    private func dropSessionOfUnrecordedMarker() {
        guard session == nil, let s = try? store.loadSession() else { return }
        do {
            try store.deleteSession()
            Log.info("removed session.json until \(iso(s.endsAt)): it was beside a pending-start marker that no journaled start accounts for, so it is never resumed")
        } catch {
            unrecordedMarkerSession = true
            fail("could not remove session.json beside a pending-start marker that no journaled start accounts for: \(error.localizedDescription). Its session is ended rather than resumed")
        }
    }

    /// Ends a start whose dialog failed in a way its status cannot vouch
    /// for (a lost answer, a wrong password, a signal, a timeout, a prompt
    /// that would not stop), from its receipt, under the receipt's lock.
    /// `dialogOver`: osascript exited by itself, so no command for the
    /// start can still begin. Otherwise, when the start's `expires` is at
    /// most 15 s away (after a timeout it is about 10 s), this waits for
    /// it rather than leave the start unsettled.
    ///
    /// A receipt that shows no command for the start turned sleep off rolls
    /// it back like a refusal (`abandonStart`), and no pmset runs, so a
    /// SleepDisabled 1 another tool set while the dialog was up stays. One
    /// that may have removes the start's session.json, publishes the
    /// settlement, gives the claim back, drops the record and undoes the
    /// start like an end. Undecided keeps the record and the claim and
    /// ends the start with the sleep undo held (`attemptHold`), however
    /// long the receipt stays locked: a command for that start may still
    /// be running pmset. The session never begins, starts are refused,
    /// and the next transaction, or backstop.sh, which the end arms,
    /// settles it and restores sleep then.
    private func endFailedStart(_ attempt: SleepOffAttempt, dialogOver: Bool, journal before: RuntimeState, session previous: Session?, error: String) async {
        attemptProblem = nil
        attemptHold = nil
        var outcome = await lockReceipt()
        var now = Self.seconds(clock())
        var verdict = receipts.verdict(for: attempt, lock: outcome, now: now, dialogOver: dialogOver)
        if case .undecided = verdict, !dialogOver, attempt.expires > now, attempt.expires - now <= 15 {
            if case let .success(held) = outcome { held.release() }
            Log.info("waiting \(attempt.expires - now) s for the failed start's answer window to end before reading its receipt")
            try? await Task.sleep(for: .seconds(attempt.expires - now + 1))
            outcome = await lockReceipt()
            now = Self.seconds(clock())
            verdict = receipts.verdict(for: attempt, lock: outcome, now: now, dialogOver: dialogOver)
        }
        switch verdict {
        case .neverWrote:
            if case let .success(held) = outcome { held.release() }
            if await abandonStart(attempt, journal: before, session: previous) {
                notifier.post(title: Self.endTitle(.startFailed, had: false), body: "No session was started, and Insomnia undid anything it changed: \(error). The receipt shows that the command behind the password dialog never turned sleep off.")
            }
            return
        case let .mayHaveWritten(reason):
            Log.info("the failed start is undone like an end: \(reason)")
            switch outcome {
            case let .success(held):
                defer { held.release() }
                do {
                    _ = try removeSessionOfUnfinishedStart(attempt)
                } catch {
                    let why = "session.json of that start could not be removed (\(error.localizedDescription))"
                    keepAttempt(attempt, verdict, because: why)
                    Log.error("the failed start stays recorded: \(why); the end below restores sleep and keeps the entry")
                    break
                }
                let resumes: ResumedSession
                do {
                    resumes = try sessionLeftToResume()
                } catch {
                    let why = "session.json could not be read to name the session this settlement leaves (\(error.localizedDescription))"
                    keepAttempt(attempt, verdict, because: why)
                    Log.error("the failed start stays recorded: \(why); the end below restores sleep and keeps the entry")
                    break
                }
                switch publishSettlement(of: attempt, resumes: resumes, under: held, { settled in try journal { $0.sleepOffAttempt = settled } }) {
                case .done:
                    break
                case let .notPublished(why):
                    keepAttempt(attempt, verdict, because: why)
                    Log.error("the failed start stays recorded: \(why); the end below restores sleep and keeps the entry")
                case let .pending(why):
                    settlementPending(why)
                    Log.error("the failed start is settled, but \(why); the end below restores sleep, and the next run finishes the settlement")
                }
            case let .failure(error):
                keepAttempt(attempt, verdict, because: "the receipt could not be locked to give the start's claim back (\(error.localizedDescription))")
            }
        case let .undecided(why):
            if case let .success(held) = outcome { held.release() }
            keepAttempt(attempt, verdict, because: why)
            fail("could not disable sleep: \(error). The start is not settled yet: \(why). It stays recorded, starts are refused until it is settled, and sleep is left as it is until then, since a command for that start may still be running")
        }
        _ = await performEnd(reason: .startFailed)
    }

    /// The menu's error line goes away after a success, except for a
    /// pending-start marker that is still in place, which keeps its line
    /// until a transaction removes it, and then for a start the journal
    /// still records, which keeps its line until a run settles it and
    /// removes it. That start's own session can go on beside the record,
    /// but every new start is refused until then.
    private func clearLastError() {
        lastError = markerProblem.map(Self.markerProblemText)
            ?? state.sleepOffAttempt.map { Self.recordedStartText($0, attemptProblem) }
    }

    /// Why a start the journal still records refuses new starts.
    static func recordedStartText(_ recorded: SleepOffAttempt, _ problem: String?) -> String {
        let why = problem ?? "it could not be settled"
        return recorded.isSettled
            ? "an earlier start is still recorded in the journal (\(why)). Starts are refused until a later run gives its claim on the receipt back"
            : "an earlier start is still recorded in the journal and is not settled (\(why)). Starts are refused until a later run settles it"
    }

    static func markerProblemText(_ problem: String) -> String {
        "the pending-start marker could not be removed (\(problem)). A password dialog left from an earlier start could still turn sleep off, so the sleep entry stays in the journal, new starts are refused, and every run retries. If no Insomnia password dialog is open, delete the file by hand"
    }

    private func warnAboutCommand(_ message: String) {
        commandWarning = message
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

    /// A reading above 0 of the kept display entry with this value, with
    /// the lid known open and the panel awake, that did not decide it
    /// (`keptDisplayReadDoubt`): its darkening is undone. Journaled for
    /// later runs, a restart included (`RuntimeState.keptDisplayReadLit`).
    /// If the journal cannot be written the record is owed, so this
    /// process still holds it (see `owedEdits`), and an end does not let
    /// Quit go until it lands (`performEnd`). A crash, a forced quit or a
    /// lost disk before then leaves the next launch without it, as before
    /// any reading.
    private func noteKeptDisplayReadLit(_ saved: Float) {
        guard effectiveState.keptDisplayReadLit != saved else { return }
        do {
            try journal { $0.keptDisplayReadLit = saved }
        } catch {
            owedEdits.displayReadLit = saved
            Log.error("display brightness \(saved), kept after a refused restore, read above 0, but the journal could not record it: \(error.localizedDescription); this process holds it, and the next journal write or transaction tries again")
        }
    }

    /// The level was set since the refused restore: the entry is done, and
    /// is cleared without a write. If the journal cannot be written the
    /// clear is owed (see `owedEdits`): the entry is not read or written
    /// again, the next write that succeeds clears it, and the re-read keeps
    /// trying until one does.
    private func clearSetSince(_ what: String, saved: Float, now: Float, owed: WritableKeyPath<OwedEdits, KeptEdit?>, errors: inout [String], clear: (inout RuntimeState) -> Void) {
        Log.info("\(what) reads \(now), set since its restore to \(saved) was refused; left as set, and the saved value cleared")
        do {
            try journal(clear)
        } catch {
            owedEdits[keyPath: owed] = .clear(saved)
            errors.append("\(what) was set since its restore was refused, but the saved value could not be cleared: \(error.localizedDescription); it will be retried")
        }
    }

    /// A kept value written while state.json refuses its clear. The disk
    /// still flags the entry, and backstop.sh and uninstall.sh pass over
    /// it. That is now right, since the device holds the value. The clear
    /// is owed instead, replacing any unflag owed for an earlier failed
    /// write, so a lid close or an undo works from the entry as settled
    /// (`effectiveState`), not from the disk. `underLowPower` keeps the
    /// display's write owed for when Insomnia's Low Power Mode goes off,
    /// which the clear would have journaled. While the disk still holds the
    /// entry with this value and its flag, an end, Quit included, returns
    /// `.incomplete(agentArmed: false)` and stays pending, so Start is
    /// refused, and it is retried until the clear lands
    /// (`OwedEdits.settlesAKeptEntry`), since a relaunch would read the
    /// entry again and could write the saved value over a 0 set since. An
    /// entry the disk holds with another value, or without its flag, is
    /// left as it is by the owed clear, which then holds up no end.
    private func settleRestored(_ saved: Float, underLowPower: Bool = false, flag: KeyPath<RuntimeState, Bool>, owed: WritableKeyPath<OwedEdits, KeptEdit?>) {
        guard state[keyPath: flag] else { return }
        owedEdits[keyPath: owed] = .restored(saved, underLowPower: underLowPower)
    }

    /// A value kept after a refusal that this build may write after all,
    /// and the write failed: it is retried like any failed restore from
    /// now on, so the flag goes. If the journal refuses that too, the
    /// unflag is owed (see `owedEdits`): the entry counts as dirty here at
    /// once, and an end keeps it in this process, since on disk it still
    /// reads as one the agent passes over.
    private func makeRetryable(_ what: String, saved: Float, flag: WritableKeyPath<RuntimeState, Bool>, owed: WritableKeyPath<OwedEdits, KeptEdit?>, errors: inout [String]) {
        guard effectiveState[keyPath: flag] else { return }
        do {
            try journal { $0[keyPath: flag] = false }
        } catch {
            owedEdits[keyPath: owed] = .unflag(saved)
            errors.append("could not mark the \(what) for retry: \(error.localizedDescription); it still counts as not restored, and Insomnia retries it itself until the journal takes the change")
        }
    }
    private func iso(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }

    static let incompleteTitle = "Restore incomplete"
    static let notEndedTitle = "Session not ended"
    static let journalTitle = "Recovery journal unreadable"
    static let promptStuckTitle = "Password prompt still running"
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

    private func endBody(_ reason: EndReason, waiting: [SavedAudioOutput]) -> String {
        let body = endBody(reason, outputsWaiting: !waiting.isEmpty)
        return waiting.isEmpty ? body : "\(body) \(Self.stillMutedSentence(waiting))"
    }

    /// The end notification's sentence about output devices that were not
    /// connected to get their volume back.
    nonisolated static func stillMutedSentence(_ waiting: [SavedAudioOutput]) -> String {
        let names = waiting.map(\.label)
        if names.count == 1 {
            return "\(names[0]) was not connected, so it is still muted. Insomnia restores its volume when it reconnects while Insomnia is running, or at the next launch."
        }
        let list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "\(list) were not connected, so they are still muted. Insomnia restores each one's volume when it reconnects while Insomnia is running, or at the next launch."
    }

    /// The incomplete-restore notification's sentence about saved output
    /// volume that could not be restored on a connected device.
    nonisolated static func audioRetrySentence(_ delay: TimeInterval) -> String {
        "The recovery agent cannot restore output volume. Insomnia tries again in \(Int(delay)) s while it runs, and at its next launch."
    }

    /// The same for display brightness or keyboard backlight, which the
    /// next end (`restoreAll`) or the launch reconcile restores.
    nonisolated static let brightnessRetrySentence = "The recovery agent cannot restore display brightness or keyboard backlight. Insomnia tries again when a later session ends, and at its next launch."

    /// The menu line for an output device still waiting for its volume.
    nonisolated static func stillMutedLine(_ output: SavedAudioOutput) -> String {
        "\(output.label) is still muted from a lid close; Insomnia restores it when it reconnects"
    }

    private func endBody(_ reason: EndReason, outputsWaiting: Bool) -> String {
        switch reason {
        case .timer: "Time is up. Sleep is back to normal."
        case .user: "Ended by you. Sleep is back to normal."
        case .quit: "Insomnia quit. Sleep is back to normal."
        case .batteryFloor: "Battery fell below \(config.endFloor)%. Sleep is back to normal."
        case .batteryUnreadable: "The battery level could not be read twice in a row, so the \(config.endFloor)% floor could not be applied. Sleep is back to normal."
        case .thermalCritical: "Thermal state is critical. Sleep is back to normal."
        case .backstop: outputsWaiting
            ? "A previous session left changes behind. Sleep is back to normal."
            : "A previous session left changes behind; everything has been undone."
        case .recoveryUnavailable: "Insomnia could not confirm its recovery agent or the sleep setting for the session found on disk, so it ended the session. Sleep is back to normal."
        case .startFailed: "The administrator password prompt was cancelled or failed, so no session was started. Sleep is back to normal."
        case .sleepReenabled: "Sleep was turned back on while Insomnia was not running, so the session ended."
        }
    }
}
