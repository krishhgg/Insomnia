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
/// with `markExited()`. `.succeed` keeps the root command's rule: it fails
/// with exit 3 unless the marker holds the nonce. `onShow` runs when the
/// dialog is shown, before the mode's answer. Never shows anything and
/// never runs pmset.
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
    /// answer whose marker and deadline pass then fails the root command's
    /// restore check, which exits 5 before `disablesleep 1`.
    var restoreNeedsPassword: Bool {
        get { lock.withLock { _restoreNeedsPassword } }
        set { lock.withLock { _restoreNeedsPassword = newValue } }
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
                throw AdministratorPromptError.failed(status: 1, stderr: "execution error: the start that asked for this password is over; sleep was not turned off (3)")
            }
            guard now() < start.deadline else {
                throw AdministratorPromptError.failed(status: 1, stderr: "execution error: the session this password was for has already ended; sleep was not turned off (4)")
            }
            guard !restoreNeedsPassword else {
                throw AdministratorPromptError.restoreNeedsPassword(stderr: "execution error: sudo: a password is required\rturning sleep back on needs a password, so sleep was not turned off (5)")
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
    /// Arguments of each sudo call, in order, with the fakes' paths shown
    /// as /usr/bin/sudo and /usr/bin/pmset.
    let sudoCalls: [String]
}

/// What the fake sudo behind the root command lets through
/// (RootCommandProcess). Root runs anything as any user without a
/// password, as the default /etc/sudoers allows, except under
/// `noRootEntry`. The user who pressed Start (the uid the command is
/// given) gets:
enum RootSudoPolicy: String {
    /// /etc/sudoers.d/insomnia in effect: the exact restore line,
    /// `/usr/bin/pmset` followed by `PmsetSleepGuard.restoreArguments`,
    /// runs without a password, for this user only.
    case rule
    /// No rule, but another passwordless entry: `sudo -l` lists without a
    /// password, and running pmset needs the password (the admin group's
    /// rule).
    case listOnly
    /// No rule, and a credential cached by a recent sudo in a terminal:
    /// everything runs unless `-k` makes sudo ignore that credential.
    case cached
    /// No rule at all: everything needs the password.
    case noRule
    /// The rule is in effect, but root's own entry was removed from
    /// /etc/sudoers, so root cannot run anything as the user.
    case noRootEntry
}

/// A clock for the root command's `/bin/date +%s` (RootCommandProcess):
/// it reads `start` until the restore check's `pmset -a disablesleep 0`
/// has run, and `afterRestore` from then on, as if the check took that
/// long. No wall clock is involved.
struct FakeClock {
    let start: Int
    let afterRestore: Int
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
/// '<deadline>' '<uid>'`, quoted as `quoted form of` quotes it. The
/// deadline is an hour from now and the uid this process's unless given.
/// The real /usr/bin/lockf takes the marker's lock and the real /bin/date
/// tells the time. It runs as the current user with `dir` as its working
/// directory. `/usr/bin/pmset` is replaced by a fake in `dir` that records
/// its arguments, and `/usr/bin/sudo` by a fake that records its arguments
/// and answers as `policy` says (RootSudoPolicy); neither changes anything
/// on the machine. With `holdPmset` the fake pmset, once called with
/// `holdAt`, waits until `release()` (60 s at most, and only while `dir`
/// exists), so a test can act while the command holds the marker's lock.
/// `command` is `AdministratorPrompt.rootCommand` unless given (a test
/// passes the copy embedded in the AppleScript). With `clock`, `/bin/date`
/// is replaced by a fake that reads it (FakeClock).
final class RootCommandProcess {
    private let process = Process()
    private let childExit: ProcessExit
    private let err = Pipe()
    private let calls: URL
    private let sudoCalls: URL
    private let started: URL
    private let releaseFile: URL
    private let fakePmset: URL
    private let fakeSudo: URL

    init(marker: URL, nonce: String, deadline: String? = nil, uid: String? = nil, policy: RootSudoPolicy = .rule, command: String = AdministratorPrompt.rootCommand, clock: FakeClock? = nil, in dir: URL, holdPmset: Bool = false, holdAt: String = "-a disablesleep 1") throws {
        let fake = dir.appendingPathComponent("fake-pmset")
        let fakeDate = dir.appendingPathComponent("fake-date")
        let clockFile = dir.appendingPathComponent("fake-clock")
        let sudo = dir.appendingPathComponent("root-sudo")
        fakePmset = fake
        fakeSudo = sudo
        calls = dir.appendingPathComponent("pmset-calls")
        sudoCalls = dir.appendingPathComponent("root-sudo-calls")
        started = dir.appendingPathComponent("pmset-started")
        releaseFile = dir.appendingPathComponent("pmset-release")
        for file in [calls, sudoCalls, started, releaseFile] { try? FileManager.default.removeItem(at: file) }
        try """
        #!/bin/bash
        printf '%s\\n' "$*" >> "$FAKE_PMSET_CALLS"
        if [[ -n "${FAKE_CLOCK_AFTER_RESTORE:-}" && "$*" == "-a disablesleep 0" ]]; then
          printf '%s\\n' "$FAKE_CLOCK_AFTER_RESTORE" > "$FAKE_CLOCK_FILE"
        fi
        if [[ "$*" == "$FAKE_PMSET_WATCH" ]]; then
          : > "$FAKE_PMSET_STARTED"
          if [[ -n "${FAKE_PMSET_HOLD:-}" ]]; then
            i=0; while [[ ! -e "$FAKE_PMSET_HOLD" && -d "${FAKE_PMSET_HOLD%/*}" && $i -lt 1200 ]]; do sleep 0.05; i=$((i + 1)); done
          fi
        fi
        exit 0
        """.write(to: fake, atomically: true, encoding: .utf8)
        // The fake sudo. FAKE_SUDO_AS unset or 0: root invoked it, and
        // root runs the command (as the -u user, if given) without a
        // password. Any other uid: that user invoked it, and the policy
        // decides.
        let restore = ([fake.path] + PmsetSleepGuard.restoreArguments).joined(separator: " ")
        try """
        #!/bin/bash
        printf '%s\\n' "$*" >> '\(sudoCalls.path)'
        k=0; l=0; n=0; u=""
        while [[ "${1:-}" == -* ]]; do
          case "$1" in
            -k) k=1 ;; -l) l=1 ;; -n) n=1 ;;
            -u) shift; u="${1:-}" ;;
            *) echo "fake sudo: unexpected option $1" >&2; exit 2 ;;
          esac
          shift
        done
        if (( !n )); then echo "fake sudo: would have prompted" >&2; exit 2; fi
        policy='\(policy.rawValue)'
        if [[ "${FAKE_SUDO_AS:-0}" == 0 ]]; then
          if [[ "$policy" == noRootEntry ]]; then echo "sudo: root is not in the sudoers file" >&2; exit 1; fi
          if [[ -n "$u" ]]; then
            [[ "$u" =~ ^#[0-9]+$ ]] || { echo "sudo: unknown user $u" >&2; exit 1; }
            export FAKE_SUDO_AS="${u#\\#}"
          fi
          exec "$@"
        fi
        if (( l )); then
          case "$policy" in rule|listOnly|cached|noRootEntry) echo "$*"; exit 0 ;; esac
        else
          case "$policy" in
            rule|noRootEntry) [[ "$FAKE_SUDO_AS" == '\(getuid())' && "$*" == '\(restore)' ]] && exec "$@" ;;
            cached) (( k )) || exec "$@" ;;
          esac
        fi
        echo "sudo: a password is required" >&2
        exit 1
        """.write(to: sudo, atomically: true, encoding: .utf8)
        if let clock {
            try "\(clock.start)\n".write(to: clockFile, atomically: true, encoding: .utf8)
            try """
            #!/bin/bash
            [[ "$*" == +%s ]] || { echo "fake date: unexpected arguments $*" >&2; exit 2; }
            cat "$FAKE_CLOCK_FILE"
            """.write(to: fakeDate, atomically: true, encoding: .utf8)
        }
        for url in clock == nil ? [fake, sudo] : [fake, sudo, fakeDate] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let realPmset = "/usr/bin/pmset"
        let realSudo = "/usr/bin/sudo"
        let realDate = "/bin/date"
        var command = command
        if clock != nil {
            XCTAssertTrue(command.contains(realDate), "the command reads the clock through /bin/date")
            XCTAssertFalse(fakeDate.path.contains(" "), "the fake replaces an unquoted word")
            command = command.replacingOccurrences(of: realDate, with: fakeDate.path)
        }
        XCTAssertEqual(command.components(separatedBy: realPmset).count - 1, 2, "the command calls pmset twice, the restore check and the change, by absolute path")
        XCTAssertEqual(command.components(separatedBy: realSudo).count - 1, 2, "root's sudo to the user, and the user's sudo, by absolute path")
        XCTAssertFalse(fake.path.contains(" ") || sudo.path.contains(" "), "the fakes replace unquoted words")
        let line = AdministratorPrompt.markerLock + " " + appleScriptQuotedForm(marker.path)
            + " /bin/sh -c " + appleScriptQuotedForm(command.replacingOccurrences(of: realPmset, with: fake.path).replacingOccurrences(of: realSudo, with: sudo.path))
            + " insomnia " + appleScriptQuotedForm(marker.path) + " " + appleScriptQuotedForm(nonce)
            + " " + appleScriptQuotedForm(deadline ?? Self.inAnHour) + " " + appleScriptQuotedForm(uid ?? String(getuid()))

        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        process.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["FAKE_PMSET_CALLS"] = calls.path
        env["FAKE_PMSET_STARTED"] = started.path
        env["FAKE_PMSET_WATCH"] = holdAt
        env["FAKE_PMSET_HOLD"] = holdPmset ? releaseFile.path : ""
        env["FAKE_CLOCK_FILE"] = clockFile.path
        env["FAKE_CLOCK_AFTER_RESTORE"] = clock.map { String($0.afterRestore) } ?? ""
        env.removeValue(forKey: "FAKE_SUDO_AS")
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardError = err
        childExit = ProcessExit(process)
        try process.run()
    }

    var pid: pid_t { process.processIdentifier }

    static var inAnHour: String {
        PendingStart(marker: URL(fileURLWithPath: "/"), nonce: "", deadline: Date().addingTimeInterval(3600)).deadlineArgument
    }

    /// Waits (10 s at most) until the fake pmset has been called with
    /// `holdAt`.
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
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        childExit.wait()
        let recorded = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
        let sudoRecorded = (try? String(contentsOf: sudoCalls, encoding: .utf8)) ?? ""
        return RootCommandRun(
            status: process.terminationStatus,
            stderr: String(decoding: errData, as: UTF8.self),
            pmsetCalls: recorded.split(separator: "\n").map(String.init),
            sudoCalls: sudoRecorded.split(separator: "\n").map {
                $0.replacingOccurrences(of: fakeSudo.path, with: "/usr/bin/sudo").replacingOccurrences(of: fakePmset.path, with: "/usr/bin/pmset")
            }
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
func runRootCommand(marker: URL, nonce: String, deadline: String? = nil, uid: String? = nil, policy: RootSudoPolicy = .rule, command: String = AdministratorPrompt.rootCommand, clock: FakeClock? = nil, in dir: URL) throws -> RootCommandRun {
    try RootCommandProcess(marker: marker, nonce: nonce, deadline: deadline, uid: uid, policy: policy, command: command, clock: clock, in: dir).wait()
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
