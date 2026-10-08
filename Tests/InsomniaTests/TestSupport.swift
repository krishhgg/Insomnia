import Foundation
import XCTest
import InsomniaTestHome
@testable import Insomnia

actor AsyncGate {
    private var started = false
    private var opened = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !opened else { return }
        await withCheckedContinuation { gateWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func open() {
        opened = true
        let waiters = gateWaiters
        gateWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// The throwaway INSOMNIA_HOME the InsomniaTestHome loader set when this
/// bundle loaded, before XCTest discovered any test. `Log.append` and
/// `SessionManager.live` read the variable at call time and fall back to
/// the real ~/Library when it is unset, so it is set at load and never
/// unset again. A TempHome moves it to a per-test directory and moves it
/// back here on destroy, so work that outlives its test (a lifecycle task
/// draining after teardown, a reassert timer) still lands in a temp
/// directory. The loader removes the directory when the process exits.
enum ProcessTestHome {
    static let root: URL = {
        guard let raw = insomnia_test_home_root() else {
            fatalError("InsomniaTestHome did not run at load; refusing to test against the real ~/Library")
        }
        return URL(fileURLWithPath: String(cString: raw), isDirectory: true)
    }()

    /// Where INSOMNIA_HOME points right now, as the app would resolve it.
    static var current: String? {
        guard let value = getenv(Paths.environmentKey) else { return nil }
        return String(cString: value)
    }
}

/// Creates a temp INSOMNIA_HOME and points the process environment at it.
/// `destroy()` hands the variable back to `ProcessTestHome` rather than
/// unsetting it, so nothing falls through to the real ~/Library afterwards.
final class TempHome {
    let root: URL
    let paths: Paths

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv(Paths.environmentKey, root.path, 1)
        paths = Paths.fromEnvironment()
    }

    func destroy() {
        setenv(Paths.environmentKey, ProcessTestHome.root.path, 1)
        try? FileManager.default.removeItem(at: root)
    }
}

/// The administrator password dialog as a fake. Answers at once in
/// `.succeed`, `.cancel`, `.fail` and `.launchFail` (osascript could not
/// be started); in `.hang` it waits on `gate` like a
/// dialog nobody answers and then reports the timeout osascript's SIGTERM
/// would produce; in `.stuck` it reports osascript (pid 4242) as still
/// running after SIGTERM and hands out `unfinished`, which the test ends
/// with `markExited()`. `.succeed` keeps the root command's rules, in its
/// order: exit 3 unless the marker holds the nonce, 4 at or after the
/// deadline, 5 with `restoreNeedsPassword` (sudo's answers are read before
/// pmset), and 6 while `sleepOffNow` reads a 1 the start does not own.
/// None of them writes anything. `onShow` runs when the dialog is shown,
/// before the mode's answer. Never shows anything and never runs pmset.
final class FakeAdministratorPrompt: AdministratorPromptRunning, @unchecked Sendable {
    enum Mode { case succeed, cancel, fail, launchFail, hang, stuck }

    static let stuckPid: pid_t = 4242

    private let lock = NSLock()
    private var _mode: Mode = .succeed
    private var _shown = 0
    private var _unfinished: UnfinishedPrompt?
    private var _starts: [PendingStart] = []
    private var _markerAtShow: [String?] = []
    private var _onShow: (@Sendable (PendingStart) -> Void)?
    private var _now: @Sendable () -> Date = { Date() }
    private var _restoreNeedsPassword = false
    private var _sleepOffNow: @Sendable () -> Bool = { false }
    /// Opened by the test to end a `.hang`.
    let gate = AsyncGate()

    var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }
    /// How many times the dialog was shown.
    var shown: Int { lock.withLock { _shown } }
    /// The handle a `.stuck` prompt threw, once it has.
    var unfinished: UnfinishedPrompt? { lock.withLock { _unfinished } }
    /// The start each dialog was shown for, in order.
    var starts: [PendingStart] { lock.withLock { _starts } }
    /// The marker's content when each dialog was shown (nil: no file).
    var markerAtShow: [String?] { lock.withLock { _markerAtShow } }
    var onShow: (@Sendable (PendingStart) -> Void)? {
        get { lock.withLock { _onShow } }
        set { lock.withLock { _onShow = newValue } }
    }
    /// The clock a `.succeed` answer compares the start's deadline with,
    /// as the root command compares it with the system clock.
    var now: @Sendable () -> Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    /// /etc/sudoers.d/insomnia is missing or not in effect: a `.succeed`
    /// answer whose marker and deadline pass then exits 5, as the root
    /// command does when sudo does not confirm the restore, before it reads
    /// or writes pmset.
    var restoreNeedsPassword: Bool {
        get { lock.withLock { _restoreNeedsPassword } }
        set { lock.withLock { _restoreNeedsPassword = newValue } }
    }
    /// What the root command's `pmset -g` would read when the password is
    /// accepted. FakeSleepGuard points it at its own `sleepDisabled`.
    var sleepOffNow: @Sendable () -> Bool {
        get { lock.withLock { _sleepOffNow } }
        set { lock.withLock { _sleepOffNow = newValue } }
    }

    func disableSleep(_ start: PendingStart) async throws {
        let marker = try? String(contentsOf: start.marker, encoding: .utf8)
        lock.withLock {
            _shown += 1
            _starts.append(start)
            _markerAtShow.append(marker)
        }
        onShow?(start)
        switch mode {
        case .succeed:
            guard marker == start.nonce else {
                throw AdministratorPromptError.refused(rootStatus: 3, stderr: "execution error: the start that asked for this password is over; sleep was not turned off (3)")
            }
            guard now() < start.deadline else {
                throw AdministratorPromptError.refused(rootStatus: 4, stderr: "execution error: the session this password was for has already ended; sleep was not turned off (4)")
            }
            guard !restoreNeedsPassword else {
                throw AdministratorPromptError.restoreNeedsPassword(stderr: "execution error: sudo: a password is required\rsudo -k -n -l did not list this user's sudoers rules without a password, or listed Runas or command-specific Defaults, which apply to the restore but not to this check; sleep was not turned off (5)")
            }
            guard start.sleepOffIsOurs || !sleepOffNow() else {
                throw AdministratorPromptError.refused(rootStatus: 6, stderr: "execution error: pmset -g shows a SleepDisabled 1 this start did not set, or could not be read; it was left alone and sleep was not turned off (6)")
            }
            return
        case .cancel:
            throw AdministratorPromptError.cancelled
        case .fail:
            throw AdministratorPromptError.failed(status: 1, stderr: "execution error: The administrator user name or password was incorrect.")
        case .launchFail:
            throw AdministratorPromptError.launchFailed("The file osascript does not exist.")
        case .hang:
            await gate.wait()
            throw AdministratorPromptError.timedOut(seconds: AdministratorPrompt.timeout)
        case .stuck:
            let handle = UnfinishedPrompt(pid: Self.stuckPid, osascriptAlive: true)
            lock.withLock { _unfinished = handle }
            throw AdministratorPromptError.stillRunning(handle, grace: AdministratorPrompt.stopGrace)
        }
    }
}

/// Records every call; can be told to throw. `disablesleep 1` goes through
/// `prompt`, the way PmsetSleepGuard routes it through the administrator
/// dialog, so a test can see whether a path would have prompted.
final class FakeSleepGuard: SleepGuarding, @unchecked Sendable {
    let prompt = FakeAdministratorPrompt()

    init() {
        prompt.sleepOffNow = { [weak self] in self?.sleepDisabled ?? false }
    }

    private let lock = NSLock()
    private var _calls: [String] = []
    private var _sleepDisabled = false
    private var _lowPowerOn = false
    private var _lowPowerGate: AsyncGate?
    private var _sleepGate: AsyncGate?
    private var _restoreGate: AsyncGate?
    private var _restoreCalledAt: Date?
    private var _readGate: AsyncGate?
    private var _sleepSettingChecks = 0
    private var _onSleepSettingCheck: (@Sendable () -> Void)?
    private var _lastSleepOffIsOurs: Bool?
    var throwOn: Set<String> = []
    /// Commands that take effect and *then* fail (a timeout after pmset
    /// already applied the setting): the ambiguous failure shape.
    var throwAfterEffect: Set<String> = []
    private var _stillRunning: Set<String> = []
    private var _stuckExitsAtOnce = false
    private var _stuckExitStatus: Int32 = 0
    private var _stuck: [(child: UnfinishedCommand, command: String)] = []
    private var _nextPid: Int32 = 4242
    private var _unlocked: [String] = []

    var calls: [String] { lock.withLock { _calls } }
    var sleepDisabled: Bool {
        get { lock.withLock { _sleepDisabled } }
        set { lock.withLock { _sleepDisabled = newValue } }
    }
    /// Simulated battery Low Power Mode, as `pmset -g custom` would report it.
    var lowPowerOn: Bool {
        get { lock.withLock { _lowPowerOn } }
        set { lock.withLock { _lowPowerOn = newValue } }
    }
    /// Holds `lowpowermode 1` after the call is recorded, before it takes effect.
    var lowPowerGate: AsyncGate? {
        get { lock.withLock { _lowPowerGate } }
        set { lock.withLock { _lowPowerGate = newValue } }
    }
    /// Holds `disablesleep 1` after the call is recorded, before it takes effect.
    var sleepGate: AsyncGate? {
        get { lock.withLock { _sleepGate } }
        set { lock.withLock { _sleepGate = newValue } }
    }
    /// Holds `disablesleep 0` after the call is recorded, before it takes effect.
    var restoreGate: AsyncGate? {
        get { lock.withLock { _restoreGate } }
        set { lock.withLock { _restoreGate = newValue } }
    }
    /// Wall-clock time of the latest `disablesleep 0` call, taken as it arrives.
    var restoreCalledAt: Date? { lock.withLock { _restoreCalledAt } }
    /// Holds `pmset -g` after the call is recorded, before it answers.
    var readGate: AsyncGate? {
        get { lock.withLock { _readGate } }
        set { lock.withLock { _readGate = newValue } }
    }

    /// `checkSleepSettingForStart()` calls. Kept out of `calls`, which
    /// tests compare as sequences of pmset commands.
    var sleepSettingChecks: Int { lock.withLock { _sleepSettingChecks } }
    /// What the latest check was told about the journal.
    var lastSleepOffIsOurs: Bool? { lock.withLock { _lastSleepOffIsOurs } }
    /// Runs inside every check, so a test can look at what had happened
    /// by then.
    var onSleepSettingCheck: (@Sendable () -> Void)? {
        get { lock.withLock { _onSleepSettingCheck } }
        set { lock.withLock { _onSleepSettingCheck = newValue } }
    }

    /// Refuses as PmsetSleepGuard's does: while sleep is off and the
    /// journal does not own that. Its read is tested with the real guard.
    func checkSleepSettingForStart(sleepOffIsOurs: Bool) async throws {
        let (off, hook) = lock.withLock {
            _sleepSettingChecks += 1
            _lastSleepOffIsOurs = sleepOffIsOurs
            return (_sleepDisabled, _onSleepSettingCheck)
        }
        hook?()
        if off, !sleepOffIsOurs { throw SleepSettingRefusal.sleepAlreadyOff }
    }

    /// Commands reported as still running after SIGTERM
    /// (`CommandStillRunningError`): recorded, no effect yet, and a fake
    /// child in `stuck` that stays alive until `exitStuckCommands()`.
    var stillRunning: Set<String> {
        get { lock.withLock { _stillRunning } }
        set { lock.withLock { _stillRunning = newValue } }
    }
    /// With `stillRunning`: the fake child exits the moment it is reported,
    /// before the caller can look at it (the window between the grace and
    /// the transaction's own check). The command leaves `stillRunning` in
    /// the same step, so it is reported stuck once: the retry that follows
    /// its exit finds it finished whenever it runs, and a test never has to
    /// clear it in a race with that retry.
    var stuckExitsAtOnce: Bool {
        get { lock.withLock { _stuckExitsAtOnce } }
        set { lock.withLock { _stuckExitsAtOnce = newValue } }
    }
    /// The status a `stuckExitsAtOnce` child exits with.
    var stuckExitStatus: Int32 {
        get { lock.withLock { _stuckExitStatus } }
        set { lock.withLock { _stuckExitStatus = newValue } }
    }

    /// The start time and boot session a fake child with `pid` is reported
    /// with.
    static func identity(of pid: Int32) -> ProcessIdentity {
        ProcessIdentity(startedAt: 1_700_000_000 + Int64(pid), startedAtMicros: 250, bootSession: "fake-boot")
    }

    /// Fake children reported as still running, oldest first.
    var stuck: [UnfinishedCommand] { lock.withLock { _stuck.map(\.child) } }

    /// `sudo pmset` calls made with no recovery lock held
    /// (`RecoveryLock.held`); the real guard refuses to run them.
    var unlockedPrivilegedCalls: [String] { lock.withLock { _unlocked } }

    /// The operator ended them (or they finished): every stuck child exits
    /// with `status`. Exit 0 is a command that went through in the end, so
    /// its setting takes effect first; any other status changes nothing.
    func exitStuckCommands(status: Int32 = 0) {
        let children: [(child: UnfinishedCommand, command: String)] = lock.withLock {
            defer { _stuck.removeAll() }
            return _stuck
        }
        for (child, command) in children {
            if status == 0 { apply(command) }
            child.markExited(status: status)
        }
    }

    private func apply(_ command: String) {
        switch command {
        case "disablesleep 1": sleepDisabled = true
        case "disablesleep 0": sleepDisabled = false
        case "lowpowermode 1": lowPowerOn = true
        case "lowpowermode 0": lowPowerOn = false
        default: break
        }
    }

    private func record(_ c: String) throws {
        lock.withLock { _calls.append(c) }
        if !c.hasPrefix("pmset -g"), RecoveryLock.held == nil {
            lock.withLock { _unlocked.append(c) }
        }
        if throwOn.contains(c) {
            throw SleepGuardError(command: c, status: 1, stderr: "sudo: a password is required")
        }
        let reported: (child: UnfinishedCommand, exitsAtOnce: Bool)? = lock.withLock {
            guard _stillRunning.contains(c) else { return nil }
            let pid = _nextPid
            _nextPid += 1
            let child = UnfinishedCommand(exe: "/usr/bin/sudo", args: ["-n", "/usr/bin/pmset"] + c.split(separator: " ").map(String.init), pid: pid, identity: Self.identity(of: pid))
            _stuck.append((child, c))
            if _stuckExitsAtOnce { _stillRunning.remove(c) }
            return (child, _stuckExitsAtOnce)
        }
        if let reported {
            if reported.exitsAtOnce { exitStuckCommands(status: stuckExitStatus) }
            throw CommandStillRunningError(command: reported.child, reason: .timeout(seconds: 20), grace: 3)
        }
    }

    private func afterEffect(_ c: String) throws {
        if throwAfterEffect.contains(c) {
            throw ShellTimeoutError.timedOut(exe: "/usr/bin/pmset", seconds: 20)
        }
    }

    func disableSleep(_ start: PendingStart) async throws {
        try record("disablesleep 1")
        try await prompt.disableSleep(start)
        if let gate = sleepGate { await gate.wait() }
        sleepDisabled = true
        try afterEffect("disablesleep 1")
    }

    func enableSleep() async throws {
        lock.withLock { _restoreCalledAt = Date() }
        try record("disablesleep 0")
        if let gate = restoreGate { await gate.wait() }
        sleepDisabled = false
        try afterEffect("disablesleep 0")
    }

    func isSleepDisabled() async throws -> Bool {
        try record("pmset -g")
        if let gate = readGate { await gate.wait() }
        return sleepDisabled
    }

    func setLowPowerMode(_ on: Bool) async throws {
        try record("lowpowermode \(on ? 1 : 0)")
        if on, let gate = lowPowerGate { await gate.wait() }
        lowPowerOn = on
        try afterEffect("lowpowermode \(on ? 1 : 0)")
    }

    func isLowPowerModeOn() async throws -> Bool {
        try record("pmset -g custom")
        return lowPowerOn
    }
}

/// Signal layer double. Records what it was asked to signal; the identity
/// checks themselves live in `SignalProcessControl` and are tested there.
/// It keeps a small model of the kernel: which pids are stopped and which
/// have a SIGSTOP still pending. `suspend` stops each pid it does not
/// refuse, or leaves the stop pending for pids in `delayedStops`. `resume`
/// signals only a pid that is stopped right now, as the real one does, and
/// reports any other pid as gone. `cancelStops` signals every entry with
/// identity, stopped or not, and its SIGCONT discards a pending stop. An
/// entry without identity is never signaled. It can also be told that
/// SIGCONT fails for particular pids or that SIGSTOP is refused for some.
final class FakeProcessControl: ProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var _resumed: [[Int32]] = []
    private var _cancelled: [[Int32]] = []
    private var _signaled: [Int32] = []
    private var _suspended: [[Int32]] = []
    private var _failResume: Set<Int32> = []
    private var _refuseSuspend: Set<Int32> = []
    private var _delayedStops: Set<Int32> = []
    private var _pendingStops: Set<Int32> = []
    private var _stoppedNow: Set<Int32> = []
    /// Pids passed to each `resume` call.
    var resumed: [[Int32]] { lock.withLock { _resumed } }
    /// Pids passed to each `cancelStops` call.
    var cancelled: [[Int32]] { lock.withLock { _cancelled } }
    /// Pids actually reported resumed (SIGCONT delivered), across all calls.
    var signaled: [Int32] { lock.withLock { _signaled } }
    var suspended: [[Int32]] { lock.withLock { _suspended } }
    /// Pids whose SIGCONT is reported as failed (verified, still stopped).
    var failResume: Set<Int32> {
        get { lock.withLock { _failResume } }
        set { lock.withLock { _failResume = newValue } }
    }
    /// Pids the fake kernel will not stop (already stopped, exited, reused).
    var refuseSuspend: Set<Int32> {
        get { lock.withLock { _refuseSuspend } }
        set { lock.withLock { _refuseSuspend = newValue } }
    }
    /// Pids whose SIGSTOP the fake kernel accepts but has not delivered
    /// when `suspend` returns: they still look running until
    /// `deliverPendingStops`.
    var delayedStops: Set<Int32> {
        get { lock.withLock { _delayedStops } }
        set { lock.withLock { _delayedStops = newValue } }
    }
    /// SIGSTOPs sent but not delivered yet.
    var pendingStops: Set<Int32> { lock.withLock { _pendingStops } }
    /// Pids currently stopped in the fake kernel. `suspend` adds to it and a
    /// delivered SIGCONT removes from it; a test seeds it for pids stopped
    /// before the test began (by an earlier run, or by somebody else).
    var stoppedNow: Set<Int32> {
        get { lock.withLock { _stoppedNow } }
        set { lock.withLock { _stoppedNow = newValue } }
    }
    /// Called synchronously inside `suspend`, so a test can inspect disk
    /// at the moment the side effect happens.
    var onSuspend: (@Sendable ([Int32]) -> Void)?
    /// Called synchronously at the start of `cancelStops`.
    var onCancelStops: (@Sendable ([Int32]) -> Void)?

    /// The pending SIGSTOPs take effect.
    func deliverPendingStops() {
        lock.withLock {
            _stoppedNow.formUnion(_pendingStops)
            _pendingStops = []
        }
    }

    func resume(_ processes: [FrozenProcess]) -> ResumeReport {
        lock.withLock {
            _resumed.append(processes.map(\.pid))
            var report = ResumeReport()
            for p in processes {
                if !_stoppedNow.contains(p.pid) {
                    report.gone.append(p.pid) // running (perhaps with a stop still pending) or exited
                } else if p.identity == nil {
                    report.unverifiable.append(p.pid)
                } else {
                    sigcont(p.pid, into: &report)
                }
            }
            return report
        }
    }

    func cancelStops(_ processes: [FrozenProcess]) -> ResumeReport {
        onCancelStops?(processes.map(\.pid))
        return lock.withLock {
            _cancelled.append(processes.map(\.pid))
            var report = ResumeReport()
            for p in processes {
                if p.identity == nil { report.unverifiable.append(p.pid) } else { sigcont(p.pid, into: &report) }
            }
            return report
        }
    }

    /// Caller holds `lock`.
    private func sigcont(_ pid: Int32, into report: inout ResumeReport) {
        if _failResume.contains(pid) {
            report.failed.append(pid)
            return
        }
        _stoppedNow.remove(pid)
        _pendingStops.remove(pid)
        report.resumed.append(pid)
        _signaled.append(pid)
    }

    func suspend(_ processes: [FrozenProcess], expectedParents: [Int32: Int32]) -> SuspendReport {
        let pids = processes.map(\.pid)
        lock.withLock { _suspended.append(pids) }
        onSuspend?(pids)
        return lock.withLock {
            var report = SuspendReport()
            for pid in pids {
                if _refuseSuspend.contains(pid) {
                    report.skipped.append(pid)
                } else {
                    report.suspended.append(pid)
                    if _delayedStops.contains(pid) { _pendingStops.insert(pid) } else { _stoppedNow.insert(pid) }
                }
            }
            return report
        }
    }
}

extension SavedAudioOutput {
    /// The entry without its save ID, which each lid close draws at random:
    /// what a test compares against a fixture.
    var withoutSaveID: SavedAudioOutput {
        SavedAudioOutput(deviceUID: deviceUID, name: name, volume: volume, muted: muted, saveID: nil)
    }
}

/// Fake output devices by UID, one of them the default output, with a hook
/// fired inside `mute`. It starts with the built-in speakers only.
final class FakeAudioControl: AudioControlling, @unchecked Sendable {
    static let speakers = "BuiltInSpeakerDevice"
    static let speakersName = "MacBook Pro Speakers"
    private let lock = NSLock()
    private var _devices: [String: (name: String?, volume: Float, muted: Bool)]
    private var _defaultUID = FakeAudioControl.speakers
    private var _applied: [(volume: Float, muted: Bool, deviceUID: String?)] = []
    private var _mutes = 0
    private var _devicesChanged: (@Sendable () -> Void)?
    var throwOnRead = false
    var throwOnApply = false
    var onMute: (@Sendable () -> Void)?
    /// Runs after an apply landed, with the UID it was for.
    var onApply: (@Sendable (String?) -> Void)?

    init(volume: Float = 0.6, muted: Bool = false) {
        _devices = [Self.speakers: (Self.speakersName, volume, muted)]
    }

    /// The default output device's volume and mute.
    var volume: Float { lock.withLock { _devices[_defaultUID]?.volume ?? 0 } }
    var muted: Bool { lock.withLock { _devices[_defaultUID]?.muted ?? false } }
    var applied: [(volume: Float, muted: Bool, deviceUID: String?)] { lock.withLock { _applied } }
    var mutes: Int { lock.withLock { _mutes } }

    /// A connected device's volume and mute; nil when it is not connected.
    func device(_ uid: String) -> (volume: Float, muted: Bool)? {
        lock.withLock { _devices[uid].map { ($0.volume, $0.muted) } }
    }

    /// Connects a device and makes it the default output, as plugging in
    /// a headset does. Does not call the devices-changed handler; tests
    /// that need it call `fireDevicesChanged()`.
    func connect(_ uid: String, name: String? = nil, volume: Float, muted: Bool = false) {
        lock.withLock {
            _devices[uid] = (name, volume, muted)
            _defaultUID = uid
        }
    }

    /// Disconnects a device; the default output falls back to the speakers.
    func disconnect(_ uid: String) {
        lock.withLock {
            _devices[uid] = nil
            if _defaultUID == uid { _defaultUID = Self.speakers }
        }
    }

    /// Sets a connected device's volume and mute by hand, as the user does
    /// in Sound settings; not recorded as an apply.
    func set(_ uid: String, volume: Float, muted: Bool) {
        lock.withLock { _devices[uid]?.volume = volume; _devices[uid]?.muted = muted }
    }

    /// Calls the handler SessionManager registered, as CoreAudio does when
    /// a device connects or disconnects.
    func fireDevicesChanged() {
        let handler = lock.withLock { _devicesChanged }
        handler?()
    }

    func read() throws -> AudioOutput {
        if throwOnRead { throw AudioControlError(what: "read", status: -1) }
        return lock.withLock {
            let d = _devices[_defaultUID] ?? (nil, 0, false)
            return AudioOutput(deviceUID: _defaultUID, name: d.name, volume: d.volume, muted: d.muted)
        }
    }

    func read(deviceUID: String) throws -> AudioOutput {
        if throwOnRead { throw AudioControlError(what: "read", status: -1) }
        return try lock.withLock {
            guard let d = _devices[deviceUID] else { throw AudioDeviceMissingError(deviceUID: deviceUID) }
            return AudioOutput(deviceUID: deviceUID, name: d.name, volume: d.volume, muted: d.muted)
        }
    }

    func apply(volume: Float, muted: Bool, deviceUID: String?) throws {
        if throwOnApply { throw AudioControlError(what: "apply", status: -1) }
        try lock.withLock {
            let uid = deviceUID ?? _defaultUID
            guard _devices[uid] != nil else { throw AudioDeviceMissingError(deviceUID: uid) }
            _devices[uid]?.volume = volume
            _devices[uid]?.muted = muted
            _applied.append((volume, muted, deviceUID))
        }
        onApply?(deviceUID)
    }

    func mute(deviceUID: String) throws {
        try lock.withLock {
            guard _devices[deviceUID] != nil else { throw AudioDeviceMissingError(deviceUID: deviceUID) }
            _devices[deviceUID]?.muted = true
            _mutes += 1
        }
        onMute?()
    }

    func onDevicesChanged(_ handler: @escaping @Sendable () -> Void) throws {
        lock.withLock { _devicesChanged = handler }
    }
}

/// Fake built-in display with a hook fired inside `setBrightness`.
final class FakeDisplayDimmer: DisplayDimming, @unchecked Sendable {
    private let lock = NSLock()
    private var _brightness: Float
    private var _sets: [Float] = []
    private var _sleepRequests = 0
    private var _wakes = 0
    private var _asleep = false
    var throwOnRead = false
    var throwOnSet = false
    var throwOnSleep = false
    /// Called synchronously inside `setBrightness`, so a test can inspect
    /// disk at the moment the side effect happens.
    var onSet: (@Sendable (Float) -> Void)?

    init(brightness: Float = 0.7) {
        _brightness = brightness
    }

    var brightness: Float {
        get { lock.withLock { _brightness } }
        set { lock.withLock { _brightness = newValue } }
    }
    /// Models `CGDisplayIsAsleep`; a read while asleep is the idle-dim value.
    var asleep: Bool {
        get { lock.withLock { _asleep } }
        set { lock.withLock { _asleep = newValue } }
    }
    /// Every value written, in order.
    var sets: [Float] { lock.withLock { _sets } }
    var sleepRequests: Int { lock.withLock { _sleepRequests } }
    var wakes: Int { lock.withLock { _wakes } }

    func isAsleep() -> Bool { asleep }

    func readBrightness() throws -> Float {
        if throwOnRead { throw DisplayPowerError(what: "read brightness") }
        return brightness
    }

    func setBrightness(_ value: Float) throws {
        if throwOnSet { throw DisplayPowerError(what: "set brightness") }
        lock.withLock {
            _brightness = value
            _sets.append(value)
        }
        onSet?(value)
    }

    func requestSleep() throws {
        if throwOnSleep { throw DisplayPowerError(what: "IORequestIdle") }
        lock.withLock { _sleepRequests += 1 }
    }

    func wake() {
        lock.withLock { _wakes += 1 }
    }
}

/// Fake keyboard backlight; `brightness` nil models a Mac without one.
final class FakeKeyboardBacklight: KeyboardBacklighting, @unchecked Sendable {
    private let lock = NSLock()
    private var _brightness: Float?
    private var _sets: [Float] = []
    private var _suppressedOrDimmed = false
    var throwOnRead = false
    var throwOnSet = false
    /// Called synchronously inside `setBrightness`.
    var onSet: (@Sendable (Float) -> Void)?

    init(brightness: Float? = 0.5) {
        _brightness = brightness
    }

    var brightness: Float? {
        get { lock.withLock { _brightness } }
        set { lock.withLock { _brightness = newValue } }
    }
    /// Models display-sleep suppression or the keyboard's own idle dim; a
    /// read while suppressed is 0.
    var suppressedOrDimmed: Bool {
        get { lock.withLock { _suppressedOrDimmed } }
        set { lock.withLock { _suppressedOrDimmed = newValue } }
    }
    var sets: [Float] { lock.withLock { _sets } }

    func isSuppressedOrDimmed() -> Bool { suppressedOrDimmed }

    func readBrightness() throws -> Float? {
        if throwOnRead { throw DisplayPowerError(what: "read keyboard backlight") }
        return brightness
    }

    func setBrightness(_ value: Float) throws {
        if throwOnSet { throw DisplayPowerError(what: "set keyboard backlight") }
        lock.withLock {
            _brightness = value
            _sets.append(value)
        }
        onSet?(value)
    }
}

/// In-memory `NSAppSleepDisabled` per bundle id, with a hook fired inside
/// each write so a test can inspect disk at the moment of the side effect.
final class FakeAppNapPreferences: AppNapPreferencing, @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String: Bool]
    private var _writes: [(bundleId: String, value: Bool?)] = []
    private var _unreadable: Set<String> = []
    private var _failWrites: Set<String> = []
    /// Called synchronously inside `writeSleepDisabled`.
    var onWrite: (@Sendable (String, Bool?) -> Void)?

    init(values: [String: Bool] = [:]) {
        _values = values
    }

    /// The key per bundle id as it stands now; absent ids have no key.
    var values: [String: Bool] {
        get { lock.withLock { _values } }
        set { lock.withLock { _values = newValue } }
    }
    /// Every write, in order; nil means the key was deleted.
    var writes: [(bundleId: String, value: Bool?)] { lock.withLock { _writes } }
    /// Bundle ids whose value reads as something that is not a boolean.
    var unreadable: Set<String> {
        get { lock.withLock { _unreadable } }
        set { lock.withLock { _unreadable = newValue } }
    }
    /// Bundle ids whose writes fail (cfprefsd refused the synchronize).
    var failWrites: Set<String> {
        get { lock.withLock { _failWrites } }
        set { lock.withLock { _failWrites = newValue } }
    }

    func readSleepDisabled(bundleId: String) throws -> Bool? {
        if unreadable.contains(bundleId) { throw AppNapError(bundleId: bundleId, detail: "is not a boolean; left alone") }
        return lock.withLock { _values[bundleId] }
    }

    func writeSleepDisabled(_ value: Bool?, bundleId: String) throws {
        if failWrites.contains(bundleId) { throw AppNapError(bundleId: bundleId, detail: "could not be written") }
        lock.withLock {
            _values[bundleId] = value
            _writes.append((bundleId, value))
        }
        onWrite?(bundleId, value)
    }
}

/// Freezer over an injected process snapshot; signals go to a FakeProcessControl.
final class FakeFreezer: Freezing, @unchecked Sendable {
    private let lock = NSLock()
    var apps: [RunningApp]
    var processes: [ProcessEntry]
    let control: FakeProcessControl
    let selfBundleId: String

    init(apps: [RunningApp], processes: [ProcessEntry], control: FakeProcessControl, selfBundleId: String = Paths.bundleIdentifier) {
        self.apps = apps
        self.processes = processes
        self.control = control
        self.selfBundleId = selfBundleId
    }

    func plan(bundleIds: [String], config: Config, applyDenylist: Bool) -> [FreezeGroup] {
        lock.withLock {
            FreezePlanner.groups(bundleIds: bundleIds, apps: apps, processes: processes, config: config, selfBundleId: selfBundleId, applyDenylist: applyDenylist)
        }
    }

    func plan(config: Config) -> [FreezeGroup] {
        lock.withLock {
            FreezePlanner.groups(
                bundleIds: FreezePlanner.lidCloseBundleIds(config: config, apps: apps, selfBundleId: selfBundleId),
                apps: apps, processes: processes, config: config, selfBundleId: selfBundleId, applyDenylist: true
            )
        }
    }

    func suspend(_ processes: [FrozenProcess], expectedParents: [Int32: Int32]) -> SuspendReport {
        control.suspend(processes, expectedParents: expectedParents)
    }
    func resume(_ processes: [FrozenProcess]) -> ResumeReport { control.resume(processes) }
    func cancelStops(_ processes: [FrozenProcess]) -> ResumeReport { control.cancelStops(processes) }
}

// MARK: Identity conveniences for fixtures

extension ProcessIdentity {
    /// Fixture identity: start seconds only, in the fixture boot session.
    init(startedAt: Int64) {
        self.init(startedAt: startedAt, startedAtMicros: 0, bootSession: "boot")
    }
}

extension ProcessEntry {
    init(pid: Int32, ppid: Int32, startedAt: Int64, stopped: Bool = false) {
        self.init(pid: pid, ppid: ppid, identity: ProcessIdentity(startedAt: startedAt), stopped: stopped)
    }
}

extension FrozenProcess {
    /// nil start time models a legacy `frozenPids` entry.
    init(pid: Int32, startedAt: Int64?) {
        self.init(pid: pid, identity: startedAt.map { ProcessIdentity(startedAt: $0) })
    }
}

extension ProcessSignalState {
    init(ppid: Int32, stopped: Bool, startedAt: Int64) {
        self.init(ppid: ppid, stopped: stopped, identity: ProcessIdentity(startedAt: startedAt))
    }
}

/// Mutable clamshell reading for reconcile gating tests.
final class FakeClamshell: @unchecked Sendable {
    private let lock = NSLock()
    private var _closed: Bool?
    init(_ closed: Bool? = false) { _closed = closed }
    var closed: Bool? {
        get { lock.withLock { _closed } }
        set { lock.withLock { _closed = newValue } }
    }
}

/// What the process table holds, for `SessionManager.processLookup`: a pid
/// not listed is gone.
final class FakeProcessTable: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [Int32: ProcessLookup] = [:]
    var entries: [Int32: ProcessLookup] {
        get { lock.withLock { _entries } }
        set { lock.withLock { _entries = newValue } }
    }
    func lookup(_ pid: Int32) -> ProcessLookup { entries[pid] ?? .absent }

    /// `pid` is running as a process with `identity`.
    func run(_ pid: Int32, as identity: ProcessIdentity) {
        entries[pid] = .present(ProcessSignalState(ppid: 1, stopped: false, identity: identity))
    }
}

final class FakeBackstop: BackstopScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _arms = 0
    private var _failArm = false
    private var _armGate: AsyncGate?
    /// Successful `arm()` calls.
    var arms: Int { lock.withLock { _arms } }
    var failArm: Bool {
        get { lock.withLock { _failArm } }
        set { lock.withLock { _failArm = newValue } }
    }
    /// Holds `arm()` before it answers, like a slow launchctl.
    var armGate: AsyncGate? {
        get { lock.withLock { _armGate } }
        set { lock.withLock { _armGate = newValue } }
    }
    func arm() async throws {
        if let gate = armGate { await gate.wait() }
        if failArm { throw BackstopError(message: "fake launchd refused") }
        lock.withLock { _arms += 1 }
    }
    private var _outdatedScript = false
    private var _checks = 0
    /// The installed backstop.sh is one that cannot void a dialog.
    var outdatedScript: Bool {
        get { lock.withLock { _outdatedScript } }
        set { lock.withLock { _outdatedScript = newValue } }
    }
    /// `checkVoidsPrompts()` calls, passed or not.
    var checks: Int { lock.withLock { _checks } }
    func checkVoidsPrompts() throws {
        let outdated = lock.withLock { _checks += 1; return _outdatedScript }
        if outdated { throw BackstopError(message: "the installed backstop.sh is older than this build; run scripts/install.sh again") }
    }
}

/// A mutable fake clock usable from the @Sendable clock closure.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
struct Harness {
    let home: TempHome
    let guardFake: FakeSleepGuard
    /// The administrator dialog behind `guardFake`'s `disablesleep 1`.
    var prompt: FakeAdministratorPrompt { guardFake.prompt }
    let procs: FakeProcessControl
    let backstop: FakeBackstop
    let clock: FakeClock
    let store: Store
    let audio: FakeAudioControl
    let display: FakeDisplayDimmer
    let keyboard: FakeKeyboardBacklight
    let appNap: FakeAppNapPreferences
    let notifier: RecordingNotifier
    let clamshell: FakeClamshell
    let processes: FakeProcessTable

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        home = TempHome()
        guardFake = FakeSleepGuard()
        procs = FakeProcessControl()
        backstop = FakeBackstop()
        clock = FakeClock(now)
        store = Store(paths: home.paths)
        audio = FakeAudioControl()
        display = FakeDisplayDimmer()
        keyboard = FakeKeyboardBacklight()
        appNap = FakeAppNapPreferences()
        notifier = RecordingNotifier()
        clamshell = FakeClamshell(false)
        processes = FakeProcessTable()
        let c = clock
        guardFake.prompt.now = { c.now }
    }

    /// `lockTimeout` is short so contention tests fail closed quickly;
    /// `retryDelay` is long so the in-process retry never fires by accident;
    /// `reassertDelay` likewise, so the second display/keyboard write after
    /// a restore never lands in a test that did not ask for it.
    /// `sleepGuard` replaces `guardFake` for a test that drives the real
    /// PmsetSleepGuard against a fake sudo and pmset.
    func makeManager(
        lockTimeout: TimeInterval = 0.3,
        retryDelay: TimeInterval = 60,
        markerLockTimeout: TimeInterval = 0.3,
        reassertDelay: Duration = .seconds(3600),
        sleepGuard: (any SleepGuarding)? = nil
    ) -> SessionManager {
        let c = clock
        let lid = clamshell
        let table = processes
        return SessionManager(
            paths: home.paths,
            sleepGuard: sleepGuard ?? guardFake,
            processControl: procs,
            backstop: backstop,
            audio: audio,
            display: display,
            keyboard: keyboard,
            appNap: appNap,
            notifier: notifier,
            clamshell: { lid.closed },
            clock: { c.now },
            processLookup: { table.lookup($0) },
            recoveryLockTimeout: lockTimeout,
            recoveryRetryDelay: retryDelay,
            markerLockTimeout: markerLockTimeout,
            reassertDelay: reassertDelay
        )
    }
}

/// Runs `request` in a new main-actor task and returns that task once the
/// request has been called and the task has let go of the main actor: at
/// its first suspension, or because it finished. Lifecycle requests join
/// the queue before their first suspension, so a request made while an
/// earlier operation is held is queued behind it when this returns. Fails
/// the test if the task never ran. Release the held operation, then await
/// the returned task; awaiting it first would deadlock.
@MainActor
func runUntilSuspended<T: Sendable>(
    _ request: @escaping @MainActor @Sendable () async -> T,
    file: StaticString = #filePath, line: UInt = #line
) async -> Task<T, Never> {
    let called = MainActorFlag()
    let task = Task { @MainActor in
        called.isSet = true
        return await request()
    }
    for _ in 0..<1000 where !called.isSet { await Task.yield() }
    XCTAssertTrue(called.isSet, "the request never ran", file: file, line: line)
    return task
}

@MainActor
private final class MainActorFlag {
    var isSet = false
}

/// Yields a few times so that tasks created just now can run. Nothing
/// confirms they did, so use it only where the test has no handle on the
/// request (controller actions that start their own tasks), and
/// `runUntilSuspended` everywhere else.
@MainActor
func settleQueuedRequests() async {
    for _ in 0..<5 { await Task.yield() }
}

/// What `AdministratorPrompt.rootCommand` did in one run.
struct RootCommandRun {
    let status: Int32
    let stderr: String
    /// Arguments of each pmset call, in order.
    let pmsetCalls: [String]
    /// Who ran each pmset call, in the same order: `root`, or the uid the
    /// fake sudo switched to.
    let pmsetAs: [String]
    /// Arguments of each sudo call, in order: root's, and each sudo of the
    /// user's it started. The fakes' paths are shown as /usr/bin/sudo,
    /// /usr/bin/env and /usr/bin/pmset.
    let sudoCalls: [String]
    /// Arguments of each /usr/bin/env call, shown the same way.
    let envCalls: [String]
    /// The fake machine's SleepDisabled once the command has exited: what
    /// the fake pmset last wrote, or what the test or a simulated other
    /// tool set (`0`, `1`, or `fail`).
    let sleepDisabled: String
}

/// What sudo prints, built the way sudo 1.9.17p2 builds it (Apple's
/// sudo-114.100.11 carries the same code), for the fake sudo behind the
/// root command and for the tests that feed the root command's awk
/// programs. None of it was captured from a running sudo: each shape
/// follows format strings in the source kept with the round 18 evidence.
/// `sudo -V` comes from src/sudo.c (`Sudo version %s`) and each plugin's
/// version function: plugins/sudoers/policy.c (the policy plugin and
/// grammar lines; more only for root), iolog.c and audit.c. `sudo -l`
/// comes from display_privs in plugins/sudoers/display.c, with Defaults
/// as sudoers_format_default in fmtsudoers.c writes them, and `sudo -ll
/// command` from display_cmnd and display_cmndspec_long. Neither wraps
/// on a pipe: display_privs sets the width to 0 for a FIFO, and
/// display_cmnd always does.
enum SudoFormat {
    static let version = "1.9.17p2"

    /// `sudo -V` as a user other than root: sudo's line, the sudoers
    /// policy plugin's two lines, then one line per other plugin loaded,
    /// by default sudoers' own I/O and audit plugins.
    static func versionOutput(_ v: String = version, io: Bool = true, audit: Bool = true, more: [String] = []) -> String {
        var lines = ["Sudo version \(v)", "Sudoers policy plugin version \(v)", "Sudoers file grammar version 50"]
        if io { lines.append("Sudoers I/O plugin version \(v)") }
        if audit { lines.append("Sudoers audit plugin version \(v)") }
        return (lines + more).map { $0 + "\n" }.joined()
    }

    /// The Defaults in macOS's own /etc/sudoers, as `sudo -l` prints them:
    /// `+=` with no blanks around it, and a value with a blank in double
    /// quotes.
    static let macDefaults = [
        "env_reset", "env_keep+=BLOCKSIZE", "env_keep+=\"COLORFGBG COLORTERM\"", "env_keep+=__CF_USER_TEXT_ENCODING",
        "env_keep+=\"CHARSET LANG LANGUAGE LC_ALL LC_COLLATE LC_CTYPE\"", "env_keep+=\"LC_MESSAGES LC_MONETARY LC_NUMERIC LC_TIME\"",
        "env_keep+=\"LINES COLUMNS\"", "env_keep+=LSCOLORS", "env_keep+=SSH_AUTH_SOCK", "env_keep+=TZ",
        "env_keep+=\"DISPLAY XAUTHORIZATION XAUTHORITY\"", "env_keep+=\"EDITOR VISUAL\"", "env_keep+=\"HOME MAIL\"",
        "lecture_file=/etc/sudo_lecture", "!log_allowed",
    ]

    /// `sudo -l`: the Defaults that apply to the user, then any Defaults
    /// bound to a Runas user or a command, each group under its header and
    /// followed by a blank line, then one line per matching sudoers line,
    /// `(runas) TAGS: command`.
    static func listing(user: String = "user", host: String = "mac", defaults: [String] = macDefaults, bound: [String] = [], rules: [String]) -> String {
        var text = ""
        if !defaults.isEmpty {
            text += "Matching Defaults entries for \(user) on \(host):\n    " + defaults.joined(separator: ", ") + "\n\n"
        }
        if !bound.isEmpty {
            text += "Runas and Command-specific defaults for \(user):\n" + bound.map { "    " + $0 }.joined(separator: "\n") + "\n\n"
        }
        return text + "User \(user) may run the following commands on \(host):\n" + rules.map { "    \($0)\n" }.joined()
    }

    /// One rule in `sudo -ll`'s long form: where it came from, its run-as
    /// user, its options (an `Options:` line only when it has any), any
    /// limits, then its commands, each after a tab.
    static func longEntry(source: String = "Sudoers entry: /private/etc/sudoers.d/insomnia", runAsUsers: String = "root", options: [String] = ["!authenticate"], limits: [String] = [], commands: [String]) -> String {
        var text = source + "\n    RunAsUsers: \(runAsUsers)\n"
        if !options.isEmpty { text += "    Options: " + options.joined(separator: ", ") + "\n" }
        text += limits.map { "    \($0)\n" }.joined()
        return text + "    Commands:\n" + commands.map { "\t\($0)\n" }.joined()
    }

    /// `sudo -ll command` when the last rule that matches allows it: that
    /// rule's long form, then `Matched:` and the command as asked. When
    /// that rule denies it, or no rule matches, sudo prints nothing to
    /// stdout and exits 1.
    static func check(_ entry: String, matched: String) -> String {
        entry + "    Matched: \(matched)\n"
    }
}

/// One answer of the fake sudo: what it prints, and its exit status.
struct SudoAnswer {
    var stdout = ""
    var stderr = ""
    var status: Int32 = 0

    /// sudo -n when it would have to ask for a password.
    static let passwordRequired = SudoAnswer(stderr: "sudo: a password is required\n", status: 1)
}

/// What the fake sudo answers under one RootSudoPolicy.
struct SudoAnswers {
    /// `sudo -V`, as the user.
    var version = SudoAnswer(stdout: SudoFormat.versionOutput())
    /// `sudo -k -n -l`.
    var listing: SudoAnswer
    /// `sudo -k -n -ll <the restore line>`.
    var check: SudoAnswer
    /// Root's `sudo -n -u #<uid> ...` when root may not switch to the
    /// user; nil when it may.
    var root: SudoAnswer?
    /// The commands the user may run without a password, as given to sudo.
    var runs: [String]
}

/// A sudoers policy for the fake sudo behind the root command
/// (RootCommandProcess, FakeDialogMachine). Root runs anything as any user
/// without a password, as macOS's `root ALL = (ALL) ALL` allows, except
/// under `noRootEntry`. The user who pressed Start (the uid the command is
/// given) is an administrator, whose `%admin ALL = (ALL) ALL` needs a
/// password, and has:
enum RootSudoPolicy: String, CaseIterable {
    /// /etc/sudoers.d/insomnia as install.sh writes it: the restore line
    /// and the two Low Power Mode lines, NOPASSWD, as root, for this user.
    case rule
    /// The same, with sudo naming the file /etc/sudoers.d/insomnia (an
    /// `#includedir /etc/sudoers.d`).
    case etcPath
    /// No rule, but another NOPASSWD entry (`/usr/bin/true`), so sudo
    /// lists without a password; the restore matches only the admin
    /// group's `(ALL) ALL`, which needs one.
    case listOnly
    /// No NOPASSWD entry at all (no rule, or the rule without NOPASSWD and
    /// nothing else): a listing needs the password.
    case noRule
    /// The rule without NOPASSWD, beside another NOPASSWD entry: sudo
    /// lists, and the rule has no `Options:` line.
    case noTag
    /// The rule, then `!/usr/bin/pmset`: sudo denies the restore and
    /// prints nothing for it.
    case deny
    /// The rule, and in a later file the restore line without NOPASSWD,
    /// which wins: the restore needs a password.
    case laterRule
    /// The rule, and `Defaults!/usr/bin/pmset log_output`, which applies
    /// when the restore runs but not to a listing.
    case boundDefaults
    /// The rule as `(ALL) NOPASSWD:`.
    case runAsAll
    /// The rule as `NOPASSWD: LOG_OUTPUT:`.
    case extraOption
    /// The rule with `NOTAFTER=20261231000000Z`.
    case timeLimited
    /// The rule from LDAP.
    case ldap
    /// The rule, and a sudo that answers `-ll command` with the bare
    /// command, as `sudo -l command` does.
    case pathOnly
    /// The rule, and an answer cut off inside its command line.
    case truncated
    /// The rule, and sudo 1.9.14p3.
    case oldSudo
    /// The rule, and an approval plugin loaded beside sudoers.
    case approvalPlugin
    /// The rule, but root's own entry is gone from /etc/sudoers, so root
    /// cannot switch to the user.
    case noRootEntry

    /// The answers, for sudoers lines that name pmset as `pmset`: the
    /// real /usr/bin/pmset, or the fake standing in for it.
    func answers(pmset: String = "/usr/bin/pmset") -> SudoAnswers {
        let restore = ([pmset] + PmsetSleepGuard.restoreArguments).joined(separator: " ")
        let lines = [restore, "\(pmset) -b lowpowermode 1", "\(pmset) -b lowpowermode 0"]
        let admin = "(ALL) ALL"
        let other = "(root) NOPASSWD: /usr/bin/true"
        let ruleCheck = SudoFormat.check(SudoFormat.longEntry(commands: [restore]), matched: restore)
        func check(_ entry: String) -> SudoAnswer { SudoAnswer(stdout: SudoFormat.check(entry, matched: restore)) }
        var a = SudoAnswers(
            listing: SudoAnswer(stdout: SudoFormat.listing(rules: [admin] + lines.map { "(root) NOPASSWD: \($0)" })),
            check: SudoAnswer(stdout: ruleCheck), runs: lines)
        switch self {
        case .rule:
            break
        case .etcPath:
            a.check = check(SudoFormat.longEntry(source: "Sudoers entry: /etc/sudoers.d/insomnia", commands: [restore]))
        case .listOnly:
            a.listing.stdout = SudoFormat.listing(rules: [admin, other])
            a.check = check(SudoFormat.longEntry(source: "Sudoers entry: /private/etc/sudoers", runAsUsers: "ALL", options: [], commands: ["ALL"]))
            a.runs = []
        case .noRule:
            a.listing = .passwordRequired
            a.check = .passwordRequired
            a.runs = []
        case .noTag:
            a.listing.stdout = SudoFormat.listing(rules: [admin] + lines.map { "(root) \($0)" } + [other])
            a.check = check(SudoFormat.longEntry(options: [], commands: [restore]))
            a.runs = []
        case .deny:
            a.listing.stdout = SudoFormat.listing(rules: [admin] + lines.map { "(root) NOPASSWD: \($0)" } + ["(root) !\(pmset)"])
            a.check = SudoAnswer(status: 1)
            a.runs = []
        case .laterRule:
            a.listing.stdout = SudoFormat.listing(rules: [admin] + lines.map { "(root) NOPASSWD: \($0)" } + ["(root) \(restore)"])
            a.check = check(SudoFormat.longEntry(source: "Sudoers entry: /private/etc/sudoers.d/zz-local", options: [], commands: [restore]))
            a.runs = Array(lines.dropFirst())
        case .boundDefaults:
            a.listing.stdout = SudoFormat.listing(bound: ["Defaults!\(pmset) log_output"], rules: [admin] + lines.map { "(root) NOPASSWD: \($0)" })
        case .runAsAll:
            a.listing.stdout = SudoFormat.listing(rules: [admin] + lines.map { "(ALL) NOPASSWD: \($0)" })
            a.check = check(SudoFormat.longEntry(runAsUsers: "ALL", commands: [restore]))
        case .extraOption:
            a.listing.stdout = SudoFormat.listing(rules: [admin] + lines.map { "(root) NOPASSWD: LOG_OUTPUT: \($0)" })
            a.check = check(SudoFormat.longEntry(options: ["!authenticate", "log_output"], commands: [restore]))
        case .timeLimited:
            a.listing.stdout = SudoFormat.listing(rules: [admin] + lines.map { "(root) NOTAFTER=20261231000000Z NOPASSWD: \($0)" })
            a.check = check(SudoFormat.longEntry(limits: ["NotAfter: 20261231000000Z"], commands: [restore]))
        case .ldap:
            a.check = check(SudoFormat.longEntry(source: "LDAP Role: insomnia", commands: [restore]))
        case .pathOnly:
            a.check.stdout = restore + "\n"
        case .truncated:
            a.check.stdout = String(ruleCheck[..<ruleCheck.range(of: "disablesleep")!.lowerBound])
        case .oldSudo:
            a.version.stdout = SudoFormat.versionOutput("1.9.14p3")
        case .approvalPlugin:
            a.version.stdout = SudoFormat.versionOutput(more: ["Sample approval plugin version \(SudoFormat.version)"])
        case .noRootEntry:
            a.root = SudoAnswer(stderr: "root is not in the sudoers file.\n", status: 1)
        }
        return a
    }
}

/// Writes `answers` where fakeSudoScript reads them: `<name>.out`,
/// `.err` and `.status` for `version`, `list`, `check`, `other` (a user
/// with no sudoers lines) and, when root may not switch, `root`; and
/// `runs`, one command per line.
func writeSudoAnswers(_ answers: SudoAnswers, to dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let named: [(String, SudoAnswer?)] = [("version", answers.version), ("list", answers.listing), ("check", answers.check), ("other", .passwordRequired), ("root", answers.root)]
    for (name, answer) in named {
        for ext in ["out", "err", "status"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(name).\(ext)")) }
        guard let answer else { continue }
        try Data(answer.stdout.utf8).write(to: dir.appendingPathComponent("\(name).out"))
        try Data(answer.stderr.utf8).write(to: dir.appendingPathComponent("\(name).err"))
        try Data(String(answer.status).utf8).write(to: dir.appendingPathComponent("\(name).status"))
    }
    try Data(answers.runs.map { $0 + "\n" }.joined().utf8).write(to: dir.appendingPathComponent("runs"))
}

/// A fake /usr/bin/sudo that answers from the files writeSudoAnswers put
/// in `answers` and logs each call's arguments to `log`. `FAKE_SUDO_AS`
/// says who invoked it: `0` for root, a uid once root switched with `-u`,
/// unset for the user running the tests (as the app runs sudo). Root runs
/// any command as any user without a password, unless `root.status`
/// exists. Anyone gets the `version` answer for `-V`. The tests' user gets
/// `list` for `-k -n -l` and `check` for `-k -n -ll <restore>`, and any
/// other user the `other` answer. A command runs only for the tests' user,
/// and only when it is one of `runs`; /usr/bin/pmset, the path the app
/// runs, stands for the fake pmset that starts `restore`. Anything the
/// root command never asks (a listing without `-k -n`, a prompt) exits 2
/// with `fake sudo:`.
/// `before` and `after` are shell lines that see `$sig`, `sudo
/// <arguments>`: `before` runs before the call does anything, `after` once
/// an answer is printed.
func fakeSudoScript(log: URL, answers: URL, restore: String, before: String = "", after: String = "") -> String {
    """
    #!/bin/bash
    printf '%s\\n' "$*" >> '\(log.path)'
    sig="sudo $*"
    \(before)
    who="${FAKE_SUDO_AS:-\(getuid())}"
    k=0; l=0; n=0; v=0; u=""
    while [[ "${1:-}" == -* ]]; do
      case "$1" in
        -k) k=1 ;; -n) n=1 ;; -V) v=1 ;; -l) l=$((l + 1)) ;; -ll) l=$((l + 2)) ;;
        -u) shift; u="${1:-}" ;;
        *) echo "fake sudo: unexpected option $1" >&2; exit 2 ;;
      esac
      shift
    done
    a='\(answers.path)'
    reply() {
      /bin/cat "$a/$1.out"; /bin/cat "$a/$1.err" >&2
      rc="$(/bin/cat "$a/$1.status")"
      \(after)
      exit "$rc"
    }
    if [[ "$who" == 0 ]]; then
      (( n && !k && !l && !v )) || { echo "fake sudo: root asked for $sig" >&2; exit 2; }
      [[ -e "$a/root.status" ]] && reply root
      [[ "$u" =~ ^#[0-9]+$ ]] || { echo "sudo: unknown user $u" >&2; exit 1; }
      export FAKE_SUDO_AS="${u#\\#}"
      exec "$@"
    fi
    (( v )) && reply version
    if (( l )); then
      (( k && n )) || { echo "fake sudo: a listing without -k and -n: $sig" >&2; exit 2; }
      [[ "$who" == '\(getuid())' ]] || reply other
      (( l == 1 && $# == 0 )) && reply list
      (( l == 2 )) && [[ "$*" == '\(restore)' ]] && reply check
      echo "fake sudo: a listing the root command never asks for: $sig" >&2; exit 2
    fi
    (( n )) || { echo "fake sudo: would have prompted" >&2; exit 2; }
    cmd=("$@")
    [[ "${1:-}" == /usr/bin/pmset ]] && cmd[0]='\(restore.prefix { $0 != " " })'
    if [[ "$who" == '\(getuid())' ]] && /usr/bin/grep -qxF -- "${cmd[*]}" "$a/runs"; then exec "${cmd[@]}"; fi
    echo "sudo: a password is required" >&2
    exit 1
    """
}

/// A fake /usr/bin/env for the root command's `env -i LC_ALL=C sudo ...`.
/// It logs its arguments to `log`, exits 2 unless they start with `-i
/// LC_ALL=C`, and runs the rest with only `LC_ALL=C` and the `FAKE_`
/// variables in its environment. Those stand for the fake machine (whom
/// the fake sudo switched to, RootCommandProcess's hooks); on a real Mac
/// the uid is the kernel's, which `env -i` cannot clear.
func fakeEnvScript(log: URL) -> String {
    """
    #!/bin/bash
    printf '%s\\n' "$*" >> '\(log.path)'
    [[ "${1:-}" == -i && "${2:-}" == LC_ALL=C ]] || { echo "fake env: not -i LC_ALL=C: $*" >&2; exit 2; }
    shift 2
    keep=()
    for name in $(compgen -e FAKE_); do keep+=("$name=${!name}"); done
    exec /usr/bin/env -i LC_ALL=C "${keep[@]}" "$@"
    """
}

/// A clock for the root command's `/bin/date +%s` (RootCommandProcess):
/// it reads `start` until the call `at` (a signature, such as
/// `RootCommandProcess.ruleQuery`) has answered, and `later` from then on,
/// as if that call took that long. No wall clock is involved.
struct RootCommandClock {
    let start: Int
    let later: Int
    let at: String
}

/// The root command as `AdministratorPrompt.disableSleepScript` embeds it:
/// the AppleScript string after `/bin/sh -c " & quoted form of `, with
/// AppleScript's `\"` and `\\` read back. This is the text osascript passes
/// to `/bin/sh -c`.
func appleScriptEmbeddedRootCommand() throws -> String {
    let script = AdministratorPrompt.disableSleepScript
    let opening = "\" /bin/sh -c \" & quoted form of \""
    guard let start = script.range(of: opening)?.upperBound else {
        throw NSError(domain: "appleScriptEmbeddedRootCommand", code: 1, userInfo: [NSLocalizedDescriptionKey: "no quoted root command in the script"])
    }
    var command = ""
    var escaped = false
    for ch in script[start...] {
        if escaped {
            command.append(ch)
            escaped = false
        } else if ch == "\\" {
            escaped = true
        } else if ch == "\"" {
            return command
        } else {
            command.append(ch)
        }
    }
    throw NSError(domain: "appleScriptEmbeddedRootCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: "the quoted root command never ends"])
}

/// AppleScript's `quoted form of`: single quotes, each `'` as `'\''`.
func appleScriptQuotedForm(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The command the dialog runs as root, started the way the dialog starts
/// it: `/bin/sh -c` on the line `do shell script` builds, `<markerLock>
/// '<marker>' /bin/sh -c '<rootCommand>' insomnia '<marker>' '<nonce>'
/// '<deadline>' '<uid>' '<owned>'`, quoted as `quoted form of` quotes it.
/// The deadline is an hour from now, the uid this process's and `owned`
/// `0` unless given. The real /usr/bin/lockf takes the marker's lock and
/// the real /bin/date tells the time. It runs as the current user with
/// `dir` as its working directory, and nothing it runs changes the
/// machine: `/usr/bin/pmset`, `/usr/bin/sudo` and `/usr/bin/env` are
/// replaced by fakes in `dir`. The fake sudo answers as `policy` says
/// (RootSudoPolicy, fakeSudoScript), the fake env checks for `-i
/// LC_ALL=C` (fakeEnvScript), and the fake pmset records its arguments.
/// `command` is `AdministratorPrompt.rootCommand` unless given (a test
/// passes the copy embedded in the AppleScript). With `clock`, `/bin/date`
/// is replaced by a fake that reads it (RootCommandClock).
///
/// Calls are named by signature: `sudo <arguments>` for a sudo of the
/// user's (`versionQuery`, `listQuery`, `ruleQuery`) and `pmset
/// <arguments>` for pmset (`read`, `write`), naming pmset as
/// /usr/bin/pmset. The fake pmset keeps one SleepDisabled value in a
/// file, starting at `sleepDisabled` (`0`, `1`, or `fail`, which makes
/// `pmset -g` fail): `-g` prints it in `pmset -g`'s shape (or
/// `pmsetOutput` verbatim), and `-a disablesleep N` writes N, unless
/// `writeFails`, which makes `-a disablesleep 1` fail without writing.
/// `foreignAfter` is another tool: once the call with that signature has
/// answered, it sets SleepDisabled to `foreignSets` (`1` unless given;
/// `fail` makes the next `pmset -g` fail), once. With `holdAt`, the call
/// with that signature waits before it does anything until `release()`
/// (60 s at most, and only while `dir` exists), so a test can act while
/// the command holds the marker's lock. With `outputClosed`, the
/// command's stderr is a pipe whose reading end is already closed, as when
/// osascript has exited: a write to it raises SIGPIPE, and `stderr` comes
/// back empty.
final class RootCommandProcess {
    /// The user's `sudo -V`.
    static let versionQuery = "sudo -V"
    /// The user's `sudo -k -n -l`.
    static let listQuery = "sudo -k -n -l"
    /// The user's `sudo -k -n -ll` for the restore line.
    static let ruleQuery = "sudo -k -n -ll /usr/bin/pmset -a disablesleep 0"
    /// Root's `pmset -g`.
    static let read = "pmset -g"
    /// Root's only write, `pmset -a disablesleep 1`.
    static let write = "pmset -a disablesleep 1"

    private let process = Process()
    private let childExit: ProcessExit
    private let err = Pipe()
    private let calls: URL
    private let callers: URL
    private let sudoCalls: URL
    private let envCalls: URL
    private let started: URL
    private let releaseFile: URL
    private let fakePmset: URL
    private let fakeSudo: URL
    private let fakeEnv: URL
    private let sleepState: URL

    init(marker: URL, nonce: String, deadline: String? = nil, uid: String? = nil, policy: RootSudoPolicy = .rule, command: String = AdministratorPrompt.rootCommand, clock: RootCommandClock? = nil, sleepDisabled: String = "0", owned: String = "0", pmsetOutput: String? = nil, foreignAfter: String? = nil, foreignSets: String = "1", writeFails: Bool = false, outputClosed: Bool = false, in dir: URL, holdAt: String? = nil) throws {
        let fake = dir.appendingPathComponent("fake-pmset")
        let sudo = dir.appendingPathComponent("root-sudo")
        let env = dir.appendingPathComponent("fake-env")
        let fakeDate = dir.appendingPathComponent("fake-date")
        let clockFile = dir.appendingPathComponent("fake-clock")
        let answers = dir.appendingPathComponent("root-sudo-answers", isDirectory: true)
        let outputFile = dir.appendingPathComponent("fake-pmset-output")
        let foreignDone = dir.appendingPathComponent("fake-foreign-done")
        fakePmset = fake
        fakeSudo = sudo
        fakeEnv = env
        sleepState = dir.appendingPathComponent("fake-sleep-disabled")
        calls = dir.appendingPathComponent("pmset-calls")
        callers = dir.appendingPathComponent("pmset-as")
        sudoCalls = dir.appendingPathComponent("root-sudo-calls")
        envCalls = dir.appendingPathComponent("root-env-calls")
        started = dir.appendingPathComponent("pmset-started")
        releaseFile = dir.appendingPathComponent("pmset-release")
        for file in [calls, callers, sudoCalls, envCalls, started, releaseFile, outputFile, foreignDone] { try? FileManager.default.removeItem(at: file) }
        try Data(sleepDisabled.utf8).write(to: sleepState)
        if let pmsetOutput { try Data(pmsetOutput.utf8).write(to: outputFile) }
        try writeSudoAnswers(policy.answers(pmset: fake.path), to: answers)
        // Shell lines both fakes run, with $sig set to the call's signature.
        let before = """
        if [[ "$sig" == "$FAKE_HOLD_AT" ]]; then
          : > "$FAKE_HOLD_STARTED"
          if [[ -n "$FAKE_HOLD_RELEASE" ]]; then
            i=0; while [[ ! -e "$FAKE_HOLD_RELEASE" && -d "${FAKE_HOLD_RELEASE%/*}" && $i -lt 1200 ]]; do /bin/sleep 0.05; i=$((i + 1)); done
          fi
        fi
        """
        let after = """
        if [[ "$sig" == "$FAKE_CLOCK_AT" ]]; then printf '%s\\n' "$FAKE_CLOCK_LATER" > "$FAKE_CLOCK_FILE"; fi
        if [[ "$sig" == "$FAKE_FOREIGN_AFTER" && ! -e "$FAKE_FOREIGN_DONE" ]]; then : > "$FAKE_FOREIGN_DONE"; printf '%s' "$FAKE_FOREIGN_SETS" > "$FAKE_SLEEP_STATE"; fi
        """
        try """
        #!/bin/bash
        printf '%s\\n' "$*" >> "$FAKE_PMSET_CALLS"
        who="${FAKE_SUDO_AS:-0}"; [[ "$who" == 0 ]] && who=root
        printf '%s\\n' "$who" >> "$FAKE_PMSET_AS"
        sig="pmset $*"
        \(before)
        rc=0
        case "$*" in
          -g)
            state="$(/bin/cat "$FAKE_SLEEP_STATE")"
            if [[ "$state" == fail ]]; then echo "pmset: could not read the settings" >&2; rc=1
            elif [[ -e "$FAKE_PMSET_OUTPUT" ]]; then /bin/cat "$FAKE_PMSET_OUTPUT"
            else printf 'System-wide power settings:\\nCurrently in use:\\n standby              1\\n SleepDisabled        %s\\n sleep                1\\n' "$state"
            fi ;;
          "-a disablesleep 0") printf 0 > "$FAKE_SLEEP_STATE" ;;
          "-a disablesleep 1")
            if [[ -n "$FAKE_WRITE_FAILS" ]]; then echo "pmset: could not write the settings" >&2; rc=1
            else printf 1 > "$FAKE_SLEEP_STATE"
            fi ;;
          *) echo "fake pmset: unexpected arguments $*" >&2; rc=2 ;;
        esac
        \(after)
        exit $rc
        """.write(to: fake, atomically: true, encoding: .utf8)
        let restore = ([fake.path] + PmsetSleepGuard.restoreArguments).joined(separator: " ")
        try fakeSudoScript(log: sudoCalls, answers: answers, restore: restore, before: before, after: after).write(to: sudo, atomically: true, encoding: .utf8)
        try fakeEnvScript(log: envCalls).write(to: env, atomically: true, encoding: .utf8)
        if let clock {
            try "\(clock.start)\n".write(to: clockFile, atomically: true, encoding: .utf8)
            try """
            #!/bin/bash
            [[ "$*" == +%s ]] || { echo "fake date: unexpected arguments $*" >&2; exit 2; }
            /bin/cat "$FAKE_CLOCK_FILE"
            """.write(to: fakeDate, atomically: true, encoding: .utf8)
        }
        var executables = [fake, sudo, env]
        if clock != nil { executables.append(fakeDate) }
        for url in executables {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let realPmset = "/usr/bin/pmset"
        let realSudo = "/usr/bin/sudo"
        let realEnv = "/usr/bin/env"
        let realDate = "/bin/date"
        var command = command
        if clock != nil {
            XCTAssertEqual(command.components(separatedBy: realDate).count - 1, 1, "the command reads the clock through /bin/date, in one place")
            XCTAssertFalse(fakeDate.path.contains(" "), "the fake replaces an unquoted word")
            command = command.replacingOccurrences(of: realDate, with: fakeDate.path)
        }
        XCTAssertEqual(command.components(separatedBy: realPmset).count - 1, 4, "the command names pmset four times, by absolute path: in the rule query, in the line it expects back, in its read and in its write")
        XCTAssertEqual(command.components(separatedBy: realSudo).count - 1, 2, "root's sudo to the user, and the user's sudo, by absolute path")
        XCTAssertEqual(command.components(separatedBy: realEnv).count - 1, 1, "the env that empties the user's sudo's environment, by absolute path")
        XCTAssertFalse(fake.path.contains(" ") || sudo.path.contains(" ") || env.path.contains(" "), "the fakes replace unquoted words")
        let faked = command.replacingOccurrences(of: realPmset, with: fake.path).replacingOccurrences(of: realSudo, with: sudo.path).replacingOccurrences(of: realEnv, with: env.path)
        let line = AdministratorPrompt.markerLock + " " + appleScriptQuotedForm(marker.path)
            + " /bin/sh -c " + appleScriptQuotedForm(faked)
            + " insomnia " + appleScriptQuotedForm(marker.path) + " " + appleScriptQuotedForm(nonce)
            + " " + appleScriptQuotedForm(deadline ?? Self.inAnHour) + " " + appleScriptQuotedForm(uid ?? String(getuid()))
            + " " + appleScriptQuotedForm(owned)

        /// Signatures name pmset as /usr/bin/pmset; the fakes see the fake.
        func signature(_ s: String?) -> String { (s ?? "").replacingOccurrences(of: realPmset, with: fake.path) }
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        process.currentDirectoryURL = dir
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("FAKE_") }
        environment["FAKE_SUDO_AS"] = "0"
        environment["FAKE_PMSET_CALLS"] = calls.path
        environment["FAKE_PMSET_AS"] = callers.path
        environment["FAKE_HOLD_AT"] = signature(holdAt)
        environment["FAKE_HOLD_STARTED"] = started.path
        environment["FAKE_HOLD_RELEASE"] = holdAt == nil ? "" : releaseFile.path
        environment["FAKE_CLOCK_AT"] = signature(clock?.at)
        environment["FAKE_CLOCK_LATER"] = clock.map { String($0.later) } ?? ""
        environment["FAKE_CLOCK_FILE"] = clockFile.path
        environment["FAKE_SLEEP_STATE"] = sleepState.path
        environment["FAKE_PMSET_OUTPUT"] = outputFile.path
        environment["FAKE_FOREIGN_AFTER"] = signature(foreignAfter)
        environment["FAKE_FOREIGN_SETS"] = foreignSets
        environment["FAKE_FOREIGN_DONE"] = foreignDone.path
        environment["FAKE_WRITE_FAILS"] = writeFails ? "1" : ""
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = err
        self.outputClosed = outputClosed
        if outputClosed { try err.fileHandleForReading.close() }
        childExit = ProcessExit(process)
        try process.run()
    }

    private let outputClosed: Bool

    var pid: pid_t { process.processIdentifier }

    static var inAnHour: String {
        PendingStart(marker: URL(fileURLWithPath: "/"), nonce: "", deadline: Date().addingTimeInterval(3600)).deadlineArgument
    }

    /// Waits (10 s at most) until the call `holdAt` has started.
    func waitUntilPmsetRuns() -> Bool {
        let limit = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: started.path) {
            if Date() > limit { return false }
            usleep(10_000)
        }
        return true
    }

    func release() {
        FileManager.default.createFile(atPath: releaseFile.path, contents: nil)
    }

    func wait() -> RootCommandRun {
        let errData = outputClosed ? Data() : err.fileHandleForReading.readDataToEndOfFile()
        childExit.wait()
        func lines(_ url: URL) -> [String] {
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        func shown(_ line: String) -> String {
            line.replacingOccurrences(of: fakeSudo.path, with: "/usr/bin/sudo")
                .replacingOccurrences(of: fakeEnv.path, with: "/usr/bin/env")
                .replacingOccurrences(of: fakePmset.path, with: "/usr/bin/pmset")
        }
        return RootCommandRun(
            status: process.terminationStatus,
            stderr: String(decoding: errData, as: UTF8.self),
            pmsetCalls: lines(calls),
            pmsetAs: lines(callers),
            sudoCalls: lines(sudoCalls).map(shown),
            envCalls: lines(envCalls).map(shown),
            sleepDisabled: (try? String(contentsOf: sleepState, encoding: .utf8)) ?? ""
        )
    }
}

/// Waits (10 s at most) until `pid`, or a child of it, is /usr/bin/lockf
/// blocked in the kernel: every thread waiting and not one system call
/// made across five looks 10 ms apart. lockf blocks in exactly one place,
/// the open(2) with O_EXLOCK that takes the lock, and that open has
/// resolved the path to its file before it waits: from then on the waiter
/// holds the marker itself, and deleting the path cannot stop it from
/// getting the lock on that file.
func waitUntilLockfWaits(under pid: pid_t) -> Bool {
    func path(_ pid: pid_t) -> String? {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(decoding: buf.prefix(Int(n)), as: UTF8.self) : nil
    }
    func children(_ pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let n = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return n > 0 ? Array(pids.prefix(Int(n))) : []
    }
    /// Unix system calls made so far, or nil unless every thread is waiting.
    func blockedSyscalls(_ pid: pid_t) -> Int32? {
        var tids = [UInt64](repeating: 0, count: 16)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &tids, Int32(tids.count * MemoryLayout<UInt64>.size))
        guard bytes > 0 else { return nil }
        for tid in tids.prefix(Int(bytes) / MemoryLayout<UInt64>.size) {
            var info = proc_threadinfo()
            guard proc_pidinfo(pid, PROC_PIDTHREADINFO, tid, &info, Int32(MemoryLayout<proc_threadinfo>.size)) > 0,
                  info.pth_run_state == TH_STATE_WAITING else { return nil }
        }
        var task = proc_taskinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { return nil }
        return task.pti_syscalls_unix
    }
    let limit = Date().addingTimeInterval(10)
    var last: (pid: pid_t, syscalls: Int32)?
    var steady = 0
    while Date() < limit {
        let lockf = ([pid] + children(pid)).first { path($0) == "/usr/bin/lockf" }
        if let lockf, let count = blockedSyscalls(lockf) {
            steady = (last?.pid == lockf && last?.syscalls == count) ? steady + 1 : 0
            last = (lockf, count)
            if steady == 4 { return true }
        } else {
            steady = 0
            last = nil
        }
        usleep(10_000)
    }
    return false
}

/// Runs the root command to the end (see RootCommandProcess).
func runRootCommand(marker: URL, nonce: String, deadline: String? = nil, uid: String? = nil, policy: RootSudoPolicy = .rule, command: String = AdministratorPrompt.rootCommand, clock: RootCommandClock? = nil, sleepDisabled: String = "0", owned: String = "0", pmsetOutput: String? = nil, foreignAfter: String? = nil, foreignSets: String = "1", in dir: URL) throws -> RootCommandRun {
    try RootCommandProcess(marker: marker, nonce: nonce, deadline: deadline, uid: uid, policy: policy, command: command, clock: clock, sleepDisabled: sleepDisabled, owned: owned, pmsetOutput: pmsetOutput, foreignAfter: foreignAfter, foreignSets: foreignSets, in: dir).wait()
}

/// One fake Mac behind a Start driven end to end through the real
/// PmsetSleepGuard and OsascriptAdministratorPrompt, with no dialog and
/// nothing privileged. SleepDisabled lives in a file. The fake pmset prints
/// it for `-g` and writes it for `-a disablesleep N`. The fake sudo
/// (fakeSudoScript) answers as `policy` says, `.rule` unless set
/// (RootSudoPolicy): root runs anything as anyone, and the user runs only
/// the rule's three pmset lines, all without a password. The fake env
/// checks the root command's `env -i LC_ALL=C` (fakeEnvScript). The fake
/// osascript records the script it was given and runs the root command
/// embedded in it (`appleScriptEmbeddedRootCommand`, with pmset, sudo, env
/// and date pointed at the fakes) under the real lockf, as `do shell
/// script` would, with the marker, nonce, deadline, uid and ownership flag
/// it was given. It reports a non-zero exit the way osascript does:
/// `execution error: <stderr> (<status>)`, exit 1. The clock reads
/// `clockStart` until the root command's call `clockAt` (a
/// RootCommandProcess signature) has answered, and `clockLater` from then
/// on. `foreignDuringDialog` and `foreignAfter` are another tool setting
/// SleepDisabled to 1 once: while the dialog is up, or right after the
/// root command's call with that signature.
final class FakeDialogMachine {
    let dir: URL
    let osascript: URL
    let sudo: URL
    let pmset: URL
    private let env: URL
    private let date: URL
    private let state: URL
    private let answers: URL
    private let pmsetLog: URL
    private let sudoLog: URL
    private let envLog: URL
    private let scriptLog: URL
    private let foreignDialog: URL
    private let foreignAt: URL

    init(in dir: URL, clockStart: Int, clockLater: Int, clockAt: String = RootCommandProcess.ruleQuery) throws {
        self.dir = dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertFalse(dir.path.contains(" "), "the fakes replace unquoted words in the root command")
        osascript = dir.appendingPathComponent("osascript")
        sudo = dir.appendingPathComponent("sudo")
        pmset = dir.appendingPathComponent("pmset")
        env = dir.appendingPathComponent("env")
        date = dir.appendingPathComponent("date")
        state = dir.appendingPathComponent("sleep-disabled")
        answers = dir.appendingPathComponent("sudo-answers", isDirectory: true)
        pmsetLog = dir.appendingPathComponent("pmset-calls")
        sudoLog = dir.appendingPathComponent("sudo-calls")
        envLog = dir.appendingPathComponent("env-calls")
        scriptLog = dir.appendingPathComponent("osascript-script")
        foreignDialog = dir.appendingPathComponent("foreign-during-dialog")
        foreignAt = dir.appendingPathComponent("foreign-at")
        let clock = dir.appendingPathComponent("clock")
        let clockLaterFile = dir.appendingPathComponent("clock-later")
        let clockAtFile = dir.appendingPathComponent("clock-at")
        let rootCommand = dir.appendingPathComponent("root-command")
        try Data("0".utf8).write(to: state)
        try Data("\(clockStart)\n".utf8).write(to: clock)
        try Data("\(clockLater)\n".utf8).write(to: clockLaterFile)
        try Data(clockAt.replacingOccurrences(of: "/usr/bin/pmset", with: pmset.path).utf8).write(to: clockAtFile)
        try writeSudoAnswers(policy.answers(pmset: pmset.path), to: answers)

        // Run by both fakes once a call has answered, with $sig set to its
        // signature; only calls made by the root command (FAKE_SUDO_AS set,
        // to 0 or to the uid root switched to) move the clock or set the
        // other tool's 1.
        let after = """
        if [[ -n "${FAKE_SUDO_AS:-}" ]]; then
          if [[ -e '\(clockLaterFile.path)' && "$sig" == "$(/bin/cat '\(clockAtFile.path)')" ]]; then /bin/mv '\(clockLaterFile.path)' '\(clock.path)'; fi
          if [[ -e '\(foreignAt.path)' && "$sig" == "$(/bin/cat '\(foreignAt.path)')" ]]; then /bin/rm -f '\(foreignAt.path)'; printf 1 > '\(state.path)'; fi
        fi
        """
        try """
        #!/bin/bash
        printf '%s\\n' "$*" >> '\(pmsetLog.path)'
        sig="pmset $*"
        case "$*" in
          -g) printf 'System-wide power settings:\\nCurrently in use:\\n SleepDisabled        %s\\n sleep                1\\n' "$(/bin/cat '\(state.path)')" ;;
          "-g custom") printf 'AC Power:\\n lowpowermode         0\\n' ;;
          "-a disablesleep 0") printf 0 > '\(state.path)' ;;
          "-a disablesleep 1") printf 1 > '\(state.path)' ;;
          "-b lowpowermode 0"|"-b lowpowermode 1") ;;
          *) echo "fake pmset: unexpected arguments $*" >&2; exit 2 ;;
        esac
        \(after)
        """.write(to: pmset, atomically: true, encoding: .utf8)
        let restore = ([pmset.path] + PmsetSleepGuard.restoreArguments).joined(separator: " ")
        try fakeSudoScript(log: sudoLog, answers: answers, restore: restore, after: after).write(to: sudo, atomically: true, encoding: .utf8)
        try fakeEnvScript(log: envLog).write(to: env, atomically: true, encoding: .utf8)
        try """
        #!/bin/bash
        [[ "$*" == +%s ]] || { echo "fake date: unexpected arguments $*" >&2; exit 2; }
        /bin/cat '\(clock.path)'
        """.write(to: date, atomically: true, encoding: .utf8)
        try """
        #!/bin/bash
        [[ "$1" == -e && $# -eq 7 ]] || { echo "fake osascript: unexpected arguments" >&2; exit 2; }
        printf '%s' "$2" > '\(scriptLog.path)'
        shift 2
        if [[ -e '\(foreignDialog.path)' ]]; then rm -f '\(foreignDialog.path)'; printf 1 > '\(state.path)'; fi
        err="$(FAKE_SUDO_AS=0 \(AdministratorPrompt.markerLock) "$1" /bin/sh -c "$(cat '\(rootCommand.path)')" insomnia "$@" 2>&1 >/dev/null)"
        rc=$?
        (( rc == 0 )) && exit 0
        printf '0:1: execution error: %s (%d)\\n' "$(printf '%s' "$err" | tr '\\n' '\\r')" "$rc" >&2
        exit 1
        """.write(to: osascript, atomically: true, encoding: .utf8)
        for url in [osascript, sudo, pmset, env, date] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let embedded = try appleScriptEmbeddedRootCommand()
            .replacingOccurrences(of: "/usr/bin/pmset", with: pmset.path)
            .replacingOccurrences(of: "/usr/bin/sudo", with: sudo.path)
            .replacingOccurrences(of: "/usr/bin/env", with: env.path)
            .replacingOccurrences(of: "/bin/date", with: date.path)
        try Data(embedded.utf8).write(to: rootCommand)
    }

    /// The real guard the app builds, pointed at these fakes.
    func sleepGuard() -> PmsetSleepGuard {
        PmsetSleepGuard(prompt: OsascriptAdministratorPrompt(executable: osascript.path, timeout: 30), sudo: sudo.path, pmset: pmset.path)
    }

    /// What the fake sudo answers from now on.
    var policy: RootSudoPolicy = .rule {
        didSet { try! writeSudoAnswers(policy.answers(pmset: pmset.path), to: answers) }
    }

    /// SleepDisabled on the fake machine: `0` or `1`.
    var sleepDisabled: String {
        get { (try? String(contentsOf: state, encoding: .utf8)) ?? "" }
        set { try! Data(newValue.utf8).write(to: state) }
    }

    var foreignDuringDialog: Bool {
        get { FileManager.default.fileExists(atPath: foreignDialog.path) }
        set { if newValue { FileManager.default.createFile(atPath: foreignDialog.path, contents: nil) } else { try? FileManager.default.removeItem(at: foreignDialog) } }
    }

    /// The signature after which the other tool sets its 1, until it has;
    /// nil once it has (or when none was set).
    var foreignAfter: String? {
        get { (try? String(contentsOf: foreignAt, encoding: .utf8))?.replacingOccurrences(of: pmset.path, with: "/usr/bin/pmset") }
        set {
            if let newValue {
                try! Data(newValue.replacingOccurrences(of: "/usr/bin/pmset", with: pmset.path).utf8).write(to: foreignAt)
            } else {
                try? FileManager.default.removeItem(at: foreignAt)
            }
        }
    }

    /// The script the fake osascript was last given.
    var script: String? { try? String(contentsOf: scriptLog, encoding: .utf8) }

    /// Arguments of each pmset call, by the app and by the root command.
    func pmsetCalls() -> [String] { Self.lines(pmsetLog) }

    /// Arguments of each sudo call, with the fakes' paths shown as
    /// /usr/bin/pmset, /usr/bin/sudo and /usr/bin/env.
    func sudoCalls() -> [String] {
        Self.lines(sudoLog).map {
            $0.replacingOccurrences(of: sudo.path, with: "/usr/bin/sudo")
                .replacingOccurrences(of: env.path, with: "/usr/bin/env")
                .replacingOccurrences(of: pmset.path, with: "/usr/bin/pmset")
        }
    }

    /// Arguments of each env call, shown the same way.
    func envCalls() -> [String] {
        Self.lines(envLog).map { $0.replacingOccurrences(of: sudo.path, with: "/usr/bin/sudo").replacingOccurrences(of: pmset.path, with: "/usr/bin/pmset") }
    }

    private static func lines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}

/// Holds an flock(2) lock on `url` from this process, the way the root
/// command's lockf holds the marker, until `release()`.
final class FileLockHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(_ url: URL) throws {
        fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }

    func release() {
        lock.withLock {
            guard fd >= 0 else { return }
            close(fd)
            fd = -1
        }
    }

    deinit { release() }
}

/// A FileLockHolder a `@Sendable` callback can create and a test can
/// release later.
final class LockHolderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var holder: FileLockHolder?

    func hold(_ url: URL) {
        let h = try? FileLockHolder(url)
        lock.withLock { holder = h }
    }

    func release() {
        lock.withLock { holder?.release() }
    }
}

/// A keychain whose `set`, or `delete`, blocks its thread until
/// `release()`, the way a save or a clear waits while macOS shows a
/// keychain dialog. `release()` is the only thing tests wait on; no test
/// depends on how long the wait lasts. Two cases end it otherwise, and
/// both set `gaveUp`, which every test checks: a call on the main thread
/// does not wait at all, since the test that would release it runs there
/// (a call that belongs on `KeychainQueue` made on the main actor), and
/// the `watchdog` ends a wait no test released, so a broken test fails
/// instead of hanging the suite. The watchdog is far longer than any of
/// these tests takes. Reads, and the call that does not block, answer at
/// once from memory.
final class BlockingKeychain: KeychainStoring, @unchecked Sendable {
    enum Call { case set, delete }

    /// Fulfilled once the blocking call is inside its wait.
    let entered = XCTestExpectation(description: "the keychain call is waiting")
    private let blocks: Call
    private let gate = DispatchSemaphore(value: 0)
    private let watchdog: DispatchTimeInterval
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var waiting = false
    private var _gaveUp = false
    private var _calledOnMainThread = false

    init(blocking blocks: Call = .set, watchdog: DispatchTimeInterval = .seconds(120), items: [String: String] = [:]) {
        self.blocks = blocks
        self.watchdog = watchdog
        self.items = items
        entered.assertForOverFulfill = false
    }

    /// Whether the blocking call is inside its wait right now.
    var isWaiting: Bool { lock.withLock { waiting } }
    var gaveUp: Bool { lock.withLock { _gaveUp } }
    /// Whether the blocking call came on the main thread, and so did not wait.
    var calledOnMainThread: Bool { lock.withLock { _calledOnMainThread } }

    func release() { gate.signal() }

    func get(service: String, account: String) throws -> String? {
        lock.withLock { items["\(service)/\(account)"] }
    }

    func set(service: String, account: String, value: String) throws {
        if blocks == .set { wait() }
        lock.withLock { items["\(service)/\(account)"] = value }
    }

    func delete(service: String, account: String) throws {
        if blocks == .delete { wait() }
        _ = lock.withLock { items.removeValue(forKey: "\(service)/\(account)") }
    }

    private func wait() {
        guard !Thread.isMainThread else {
            lock.withLock {
                _calledOnMainThread = true
                _gaveUp = true
            }
            entered.fulfill()
            return
        }
        lock.withLock { waiting = true }
        entered.fulfill()
        let answered = gate.wait(timeout: .now() + watchdog) == .success
        lock.withLock {
            waiting = false
            if !answered { _gaveUp = true }
        }
    }
}

/// A FIFO at `url`, and a watchdog for it. Correct code never opens it. If
/// something does, open(2) blocks until a writer appears; the watchdog opens
/// the FIFO for writing once a second, which lets a blocked reader through
/// (it reads EOF) and records that a reader was there. A regression then
/// fails its test instead of hanging the suite.
final class FIFOWatch: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var stopped = false
    private var seen = false

    init(at url: URL) throws {
        self.url = url
        guard mkfifo(url.path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let path = url.path
        Thread.detachNewThread { [self] in
            for _ in 0..<120 {
                Thread.sleep(forTimeInterval: 1)
                if self.isStopped { return }
                // Succeeds only while a reader has the FIFO open.
                let fd = open(path, O_WRONLY | O_NONBLOCK)
                if fd >= 0 {
                    close(fd)
                    self.markSeen()
                }
            }
        }
    }

    /// True when something opened the FIFO for reading.
    var readerSeen: Bool { lock.lock(); defer { lock.unlock() }; return seen }

    /// True when the path is still this FIFO, not moved or replaced.
    var isStillFIFO: Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO
    }

    func stop() { lock.lock(); stopped = true; lock.unlock() }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func markSeen() { lock.lock(); seen = true; lock.unlock() }
}

/// Access control lists for the tests that check Insomnia leaves them alone.
enum TestACL {
    /// Gives `url` one entry letting its owner, the user running the tests,
    /// read it. On a 0200 file that entry is the only way to read it.
    static func grantOwnerRead(_ url: URL) throws {
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "user:\(String(cString: getpwuid(getuid()).pointee.pw_name)) allow read", url.path]
        let exit = ProcessExit(chmod)
        try chmod.run()
        exit.wait()
        guard chmod.terminationStatus == 0 else { throw POSIXError(.EPERM) }
    }

    /// How many ACL entries `url` has, without following a symlink.
    static func entries(_ url: URL) -> Int {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { return 0 }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var count = 0
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0 {
            count += 1
            which = ACL_NEXT_ENTRY.rawValue
        }
        return count
    }
}
