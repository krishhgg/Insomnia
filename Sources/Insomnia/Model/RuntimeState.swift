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

/// Everything Insomnia has changed on the machine and must undo.
/// Written to disk *before* each change is made and undone from disk, never
/// from memory (spec section 8 invariants).
struct RuntimeState: Codable, Equatable, Sendable {
    var sleepDisabledByUs: Bool = false
    var lowPowerSetByUs: Bool = false
    var frozenProcesses: [FrozenProcess] = []
    var dockerFrozen: Bool = false
    /// nil when mute is off or the lid is open.
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
            || savedOutputVolume != nil || savedMuted != nil
            || savedDisplayBrightness != nil || savedKeyboardBrightness != nil
    }

    private enum CodingKeys: String, CodingKey {
        case sleepDisabledByUs, lowPowerSetByUs, frozenProcesses, frozenPids, dockerFrozen, savedOutputVolume, savedMuted
        case savedDisplayBrightness, savedKeyboardBrightness, displayRestoredUnderLowPower
        case appNapOverrides
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
        savedOutputVolume = try c.decodeIfPresent(Float.self, forKey: .savedOutputVolume)
        savedMuted = try c.decodeIfPresent(Bool.self, forKey: .savedMuted)
        savedDisplayBrightness = try c.decodeIfPresent(Float.self, forKey: .savedDisplayBrightness)
        savedKeyboardBrightness = try c.decodeIfPresent(Float.self, forKey: .savedKeyboardBrightness)
        displayRestoredUnderLowPower = try c.decodeIfPresent(Float.self, forKey: .displayRestoredUnderLowPower)
        appNapOverrides = try c.decodeIfPresent([AppNapOverride].self, forKey: .appNapOverrides) ?? []
    }

    /// `frozenPids` is read for migration only and never written again, so
    /// an older backstop.sh can no longer SIGCONT an unverified pid from it.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sleepDisabledByUs, forKey: .sleepDisabledByUs)
        try c.encode(lowPowerSetByUs, forKey: .lowPowerSetByUs)
        try c.encode(frozenProcesses, forKey: .frozenProcesses)
        try c.encode(dockerFrozen, forKey: .dockerFrozen)
        try c.encodeIfPresent(savedOutputVolume, forKey: .savedOutputVolume)
        try c.encodeIfPresent(savedMuted, forKey: .savedMuted)
        try c.encodeIfPresent(savedDisplayBrightness, forKey: .savedDisplayBrightness)
        try c.encodeIfPresent(savedKeyboardBrightness, forKey: .savedKeyboardBrightness)
        try c.encodeIfPresent(displayRestoredUnderLowPower, forKey: .displayRestoredUnderLowPower)
        try c.encode(appNapOverrides, forKey: .appNapOverrides)
    }
}
