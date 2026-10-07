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

/// Points INSOMNIA_HOME at `home` for a test that does not own a TempHome,
/// and returns the closure that puts back the value it had before (the
/// loader's `ProcessTestHome.root` if it somehow had none). Call it in a
/// defer. Never unsetenv instead: `Log.append` and `SessionManager.live`
/// would then resolve the real ~/Library for the rest of the process.
func pointInsomniaHome(at home: URL) -> () -> Void {
    let previous = ProcessTestHome.current ?? ProcessTestHome.root.path
    setenv(Paths.environmentKey, home.path, 1)
    return { setenv(Paths.environmentKey, previous, 1) }
}

/// Records every call; can be told to throw.
final class FakeSleepGuard: SleepGuarding, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _sleepDisabled = false
    private var _lowPowerOn = false
    private var _lowPowerGate: AsyncGate?
    private var _sleepGate: AsyncGate?
    private var _restoreGate: AsyncGate?
    private var _restoreCalledAt: Date?
    private var _readGate: AsyncGate?
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

    func setSleepDisabled(_ disabled: Bool) async throws {
        if !disabled { lock.withLock { _restoreCalledAt = Date() } }
        try record("disablesleep \(disabled ? 1 : 0)")
        if disabled, let gate = sleepGate { await gate.wait() }
        if !disabled, let gate = restoreGate { await gate.wait() }
        sleepDisabled = disabled
        try afterEffect("disablesleep \(disabled ? 1 : 0)")
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
    }

    /// `lockTimeout` is short so contention tests fail closed quickly;
    /// `retryDelay` is long so the in-process retry never fires by accident;
    /// `reassertDelay` likewise, so the second display/keyboard write after
    /// a restore never lands in a test that did not ask for it.
    func makeManager(
        lockTimeout: TimeInterval = 0.3,
        retryDelay: TimeInterval = 60,
        reassertDelay: Duration = .seconds(3600)
    ) -> SessionManager {
        let c = clock
        let lid = clamshell
        let table = processes
        return SessionManager(
            paths: home.paths,
            sleepGuard: guardFake,
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
            reassertDelay: reassertDelay
        )
    }
}

/// Sets or clears the user immutable flag (chflags uchg) on a test file, so
/// unlink and rename onto it fail with EPERM, as for a file a person locked.
/// Tests clear it again before their temp home is removed.
func setImmutable(_ url: URL, _ on: Bool) throws {
    try FileManager.default.setAttributes([.immutable: on], ofItemAtPath: url.path)
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
        try chmod(["+a", "user:\(owner) allow read", url.path])
    }

    /// Gives directory `dir` one entry that stops its owner creating files
    /// in it, so the temp file of an atomic write fails as on a full disk.
    /// A directory inside can still be renamed: that needs
    /// add_subdirectory, which the entry leaves allowed.
    static func denyNewFiles(in dir: URL) throws {
        try chmod(["+a", "user:\(owner) deny add_file", dir.path])
    }

    /// Removes every ACL entry from `url`.
    static func removeAll(_ url: URL) throws {
        try chmod(["-N", url.path])
    }

    private static var owner: String { String(cString: getpwuid(getuid()).pointee.pw_name) }

    private static func chmod(_ arguments: [String]) throws {
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = arguments
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
