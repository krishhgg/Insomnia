import Foundation

/// What makes a pid "the process Insomnia froze": its kernel start time to
/// the microsecond and the boot session it started in. A reused pid, or the
/// same pid after a reboot, cannot match all three.
///
/// backstop.sh can only read whole seconds from `ps -o lstart`, so for an
/// entry that records `startedAtMicros` it asks the installed app binary
/// (`Insomnia --resume-frozen`, see `ResumeFrozenCommand`) to compare all
/// three and signal; the shell never signals such an entry itself. Only an
/// entry written without microseconds (an older build) is compared by the
/// shell on `startedAt` and `bootSession`, a one-second identity.
struct ProcessIdentity: Codable, Equatable, Hashable, Sendable {
    /// Seconds since the epoch, the same value `ps -o lstart` prints.
    let startedAt: Int64
    let startedAtMicros: Int32
    /// `kern.bootsessionuuid`, stable for one boot.
    let bootSession: String

    init(startedAt: Int64, startedAtMicros: Int32, bootSession: String) {
        self.startedAt = startedAt
        self.startedAtMicros = startedAtMicros
        self.bootSession = bootSession
    }
}

/// One journaled SIGSTOP. `LidActions.freeze` writes the entry without
/// identity before the signal and adds the identity only after the kernel
/// confirmed that Insomnia's own SIGSTOP stopped the process. `identity` is
/// nil for such a provisional entry (the app died or the write failed
/// before the confirmation) and for entries written by an older build as
/// `frozenPids`, which recorded the pid alone. An entry without identity is
/// never signaled, because nothing proves the stopped process is ours.
struct FrozenProcess: Codable, Equatable, Hashable, Sendable {
    let pid: Int32
    let identity: ProcessIdentity?

    init(pid: Int32, identity: ProcessIdentity?) {
        self.pid = pid
        self.identity = identity
    }

    // Flat keys so backstop.sh can read them with plutil.
    private enum CodingKeys: String, CodingKey {
        case pid, startedAt, startedAtMicros, bootSession
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        if let sec = try c.decodeIfPresent(Int64.self, forKey: .startedAt),
           let micros = try c.decodeIfPresent(Int32.self, forKey: .startedAtMicros),
           let boot = try c.decodeIfPresent(String.self, forKey: .bootSession) {
            identity = ProcessIdentity(startedAt: sec, startedAtMicros: micros, bootSession: boot)
        } else {
            identity = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pid, forKey: .pid)
        if let identity {
            try c.encode(identity.startedAt, forKey: .startedAt)
            try c.encode(identity.startedAtMicros, forKey: .startedAtMicros)
            try c.encode(identity.bootSession, forKey: .bootSession)
        }
    }
}

/// One agent app whose `NSAppSleepDisabled` Insomnia set to YES for the
/// session (spec section 5), and the value the key had in that domain
/// before: nil when it was absent, so the restore deletes the key. Flat
/// keys so backstop.sh can read them with plutil; `previous` is left out
/// of the JSON when nil.
struct AppNapOverride: Codable, Equatable, Hashable, Sendable {
    let bundleId: String
    let previous: Bool?

    init(bundleId: String, previous: Bool?) {
        self.bundleId = bundleId
        self.previous = previous
    }
}

/// One output device lid close muted, and its volume and mute before
/// (spec section 4). Restored on that device only, never on another
/// output; kept while the device is not connected. `name` is for the
/// warning that names a device still waiting, and left out of the JSON
/// when it could not be read. `saveID` is drawn afresh by each lid close
/// that writes an entry, so a later save for the same device, with the
/// same values or not, is never taken for this one, whichever copy of the
/// app wrote it. nil, and left out of the JSON, in an entry written
/// before entries had one. Flat keys so backstop.sh can check them with
/// plutil.
struct SavedAudioOutput: Codable, Equatable, Hashable, Sendable {
    let deviceUID: String
    let name: String?
    let volume: Float
    let muted: Bool
    let saveID: String?

    init(deviceUID: String, name: String?, volume: Float, muted: Bool, saveID: String?) {
        self.deviceUID = deviceUID
        self.name = name
        self.volume = volume
        self.muted = muted
        self.saveID = saveID
    }

    /// The name, or the UID when the name could not be read.
    var label: String { name ?? deviceUID }
}

/// Everything Insomnia has changed on the machine and must undo.
/// Written to disk *before* each change is made and undone from disk, never
/// from memory (spec section 8 invariants).
struct RuntimeState: Codable, Equatable, Sendable {
    var sleepDisabledByUs: Bool = false
    var lowPowerSetByUs: Bool = false
    var frozenProcesses: [FrozenProcess] = []
    var dockerFrozen: Bool = false
    /// Output devices lid close muted, one entry per device, each restored
    /// on its own device. Empty when mute is off or nothing is owed.
    var savedAudioOutputs: [SavedAudioOutput] = []
    /// The entry an earlier build wrote, without the device: restored on
    /// the default output, as that build did. Never written by a lid close
    /// now; nil once restored.
    var savedOutputVolume: Float? = nil
    var savedMuted: Bool? = nil
    /// Built-in display brightness (0...1) before the lid close set it to 0;
    /// nil when darkening is off or the lid is open.
    var savedDisplayBrightness: Float? = nil
    /// Built-in keyboard backlight (0...1) before the lid close set it to 0;
    /// nil when darkening is off, there is no backlight, or the lid is open.
    var savedKeyboardBrightness: Float? = nil
    /// A display brightness restored on lid open while `lowPowerSetByUs`:
    /// written once more right after Insomnia switches the mode off, since
    /// the mode's end rescales the panel (spec section 4). Not something
    /// to undo, so it counts neither as dirty nor as a lid action; the
    /// backstop ignores it and keeps it, and the app drops it if it finds
    /// the mode cleared by someone else.
    var displayRestoredUnderLowPower: Float? = nil
    /// Agent apps whose App Nap preference Insomnia set for the session,
    /// each with the value to put back. Not a lid action: restored at
    /// session end, at reconcile, or by the backstop with `defaults`.
    var appNapOverrides: [AppNapOverride] = []
    /// A start that may still turn sleep off, journaled with
    /// `sleepDisabledByUs` before its password dialog (SleepOffAttempt).
    /// Never set without `sleepDisabledByUs`, so it adds nothing to undo on
    /// its own; it records whether that entry may be cleared without one.
    var sleepOffAttempt: SleepOffAttempt? = nil

    /// Bare pids of every journaled freeze, for display and de-duplication.
    var frozenPids: [Int32] { frozenProcesses.map(\.pid) }

    /// A state with nothing left to undo.
    static let clean = RuntimeState()

    /// The undo entries alone: the state without
    /// `displayRestoredUnderLowPower`, a write owed after the mode rather
    /// than something to undo. Two states with equal entries owe the same
    /// undos.
    var undoEntries: RuntimeState {
        var entries = self
        entries.displayRestoredUnderLowPower = nil
        return entries
    }

    /// True when at least one entry still needs undoing.
    var isDirty: Bool {
        sleepDisabledByUs || lowPowerSetByUs || hasLidActions || !appNapOverrides.isEmpty
    }

    /// True when a lid close left something to undo on lid open: freezes,
    /// the Docker marker, saved audio, saved display or keyboard brightness.
    var hasLidActions: Bool {
        !frozenProcesses.isEmpty || dockerFrozen
            || !savedAudioOutputs.isEmpty || savedOutputVolume != nil || savedMuted != nil
            || savedDisplayBrightness != nil || savedKeyboardBrightness != nil
    }

    /// `isDirty` with the saved audio of these output devices left out. A
    /// device that is not connected does not hold up the end of a session:
    /// its entry stays for when it reconnects.
    func isDirty(leavingOutAudioOf devices: Set<String>) -> Bool {
        var rest = self
        rest.savedAudioOutputs.removeAll { devices.contains($0.deviceUID) }
        return rest.isDirty
    }

    /// `isDirty` with every saved output volume, display brightness and
    /// keyboard backlight left out: the recovery agent keeps those but only
    /// the app can restore them (CoreAudio, private frameworks).
    var isDirtyApartFromAppOnlyEntries: Bool {
        var rest = self
        rest.savedAudioOutputs = []
        rest.savedOutputVolume = nil
        rest.savedMuted = nil
        rest.savedDisplayBrightness = nil
        rest.savedKeyboardBrightness = nil
        return rest.isDirty
    }

    private enum CodingKeys: String, CodingKey {
        case sleepDisabledByUs, lowPowerSetByUs, frozenProcesses, frozenPids, dockerFrozen
        case savedAudioOutputs, savedOutputVolume, savedMuted
        case savedDisplayBrightness, savedKeyboardBrightness, displayRestoredUnderLowPower
        case appNapOverrides, sleepOffAttempt
    }

    // Tolerate missing keys so a state.json written by an older build, or by
    // backstop.sh, still decodes.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sleepDisabledByUs = try c.decodeIfPresent(Bool.self, forKey: .sleepDisabledByUs) ?? false
        lowPowerSetByUs = try c.decodeIfPresent(Bool.self, forKey: .lowPowerSetByUs) ?? false
        frozenProcesses = try c.decodeIfPresent([FrozenProcess].self, forKey: .frozenProcesses) ?? []
        // Legacy list from an older build: pids without identity.
        let legacy = try c.decodeIfPresent([Int32].self, forKey: .frozenPids) ?? []
        let known = Set(frozenProcesses.map(\.pid))
        for pid in legacy where !known.contains(pid) {
            frozenProcesses.append(FrozenProcess(pid: pid, identity: nil))
        }
        dockerFrozen = try c.decodeIfPresent(Bool.self, forKey: .dockerFrozen) ?? false
        savedAudioOutputs = try c.decodeIfPresent([SavedAudioOutput].self, forKey: .savedAudioOutputs) ?? []
        savedOutputVolume = try c.decodeIfPresent(Float.self, forKey: .savedOutputVolume)
        savedMuted = try c.decodeIfPresent(Bool.self, forKey: .savedMuted)
        savedDisplayBrightness = try c.decodeIfPresent(Float.self, forKey: .savedDisplayBrightness)
        savedKeyboardBrightness = try c.decodeIfPresent(Float.self, forKey: .savedKeyboardBrightness)
        displayRestoredUnderLowPower = try c.decodeIfPresent(Float.self, forKey: .displayRestoredUnderLowPower)
        appNapOverrides = try c.decodeIfPresent([AppNapOverride].self, forKey: .appNapOverrides) ?? []
        sleepOffAttempt = try c.decodeIfPresent(SleepOffAttempt.self, forKey: .sleepOffAttempt)
    }

    /// `frozenPids` is read for migration only and never written again, so
    /// an older backstop.sh can no longer SIGCONT an unverified pid from it.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sleepDisabledByUs, forKey: .sleepDisabledByUs)
        try c.encode(lowPowerSetByUs, forKey: .lowPowerSetByUs)
        try c.encode(frozenProcesses, forKey: .frozenProcesses)
        try c.encode(dockerFrozen, forKey: .dockerFrozen)
        try c.encode(savedAudioOutputs, forKey: .savedAudioOutputs)
        try c.encodeIfPresent(savedOutputVolume, forKey: .savedOutputVolume)
        try c.encodeIfPresent(savedMuted, forKey: .savedMuted)
        try c.encodeIfPresent(savedDisplayBrightness, forKey: .savedDisplayBrightness)
        try c.encodeIfPresent(savedKeyboardBrightness, forKey: .savedKeyboardBrightness)
        try c.encodeIfPresent(displayRestoredUnderLowPower, forKey: .displayRestoredUnderLowPower)
        try c.encode(appNapOverrides, forKey: .appNapOverrides)
        try c.encodeIfPresent(sleepOffAttempt, forKey: .sleepOffAttempt)
    }
}
