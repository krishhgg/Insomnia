import Foundation
import Network
import Security

// MARK: - Pure state machine (spec section 7)

/// Drives hotspot failover from three events. No clocks, no timers, no I/O:
/// the driver owns those and feeds `Date`s in.
struct FailoverMachine: Sendable, Equatable {
    enum Output: Sendable, Equatable {
        case joinHotspot
        case scheduleRetry(after: TimeInterval)
        case recovered(start: Date, gap: TimeInterval)
    }

    /// Seconds the path must stay unsatisfied before the first join.
    static let initialDelay: TimeInterval = 5
    /// The same, when macOS may rejoin the network that dropped by itself.
    /// Measured 2026-10-20: blips of home Wi-Fi took it 14 s, and a hotspot
    /// join started meanwhile failed with "Resource busy" as macOS joined.
    static let patientDelay: TimeInterval = 20
    /// Delays after each join attempt: 5, 10, 20, 30, 30, 30, ...
    static let backoff: [TimeInterval] = [5, 10, 20, 30]

    private(set) var outageStart: Date?
    private(set) var joins: Int = 0
    private(set) var nextAttemptAt: Date?

    var inOutage: Bool { outageStart != nil }

    static func delay(afterJoin n: Int) -> TimeInterval {
        backoff[min(max(n - 1, 0), backoff.count - 1)]
    }

    mutating func pathUnsatisfied(at now: Date, delay: TimeInterval = initialDelay) -> [Output] {
        guard outageStart == nil else { return [] }
        outageStart = now
        joins = 0
        nextAttemptAt = now.addingTimeInterval(delay)
        return [.scheduleRetry(after: delay)]
    }

    mutating func pathSatisfied(at now: Date) -> [Output] {
        guard let start = outageStart else { return [] }
        outageStart = nil
        joins = 0
        nextAttemptAt = nil
        return [.recovered(start: start, gap: max(0, now.timeIntervalSince(start)))]
    }

    mutating func timerFired(at now: Date) -> [Output] {
        guard outageStart != nil, let due = nextAttemptAt, now >= due else { return [] }
        joins += 1
        let delay = Self.delay(afterJoin: joins)
        nextAttemptAt = now.addingTimeInterval(delay)
        return [.joinHotspot, .scheduleRetry(after: delay)]
    }

    /// One handoffs.log line per outage.
    static func logLine(start: Date, end: Date, gap: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        return "\(f.string(from: end)) outage start=\(f.string(from: start)) end=\(f.string(from: end)) gap=\(Int(gap.rounded()))s"
    }

    /// "2m 10s", "45s", "1h 2m 3s".
    static func humanGap(_ gap: TimeInterval) -> String {
        let total = Int(gap.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if s > 0 || parts.isEmpty { parts.append("\(s)s") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Switching up the priority list and handing back

/// What switch-up and hand-back share: a move takes the Mac offline for a
/// few seconds, so it needs its target found strong in `sightingsNeeded`
/// scans in a row, all made on the same network, and comes at most once
/// per `cooldown`. Pure: the driver owns the clock and the scans.
struct SightingCounter: Sendable, Equatable {
    /// Scans in a row that must find a network before the move.
    static let sightingsNeeded = 2
    /// Weakest signal (RSSI, dBm) that counts as finding a network: one
    /// at the edge of its range would drop again soon after the move.
    static let minimumRSSI = -70
    /// Seconds after a move, made or not, before the next one, so a
    /// target that refuses the Mac costs a few seconds offline at most
    /// once per cooldown.
    static let cooldown: TimeInterval = 300

    /// The network the Mac was on when the sightings were counted.
    private(set) var countingOn: String?
    /// Scans in a row that found each target strong enough.
    private(set) var sightings: [String: Int] = [:]
    private(set) var lastMoveAt: Date?

    /// The Mac is on `current`: a new network starts the count again.
    /// False while a move is cooling down.
    mutating func begin(on current: String, at now: Date) -> Bool {
        if countingOn != current {
            countingOn = current
            sightings = [:]
        }
        guard let last = lastMoveAt else { return true }
        return now.timeIntervalSince(last) >= Self.cooldown
    }

    /// A scan found `signal` (RSSI by SSID). Returns the targets now
    /// found strong enough in `sightingsNeeded` scans in a row. A scan
    /// that misses a target, or finds it weak, starts its count again.
    mutating func count(_ signal: [String: Int]) -> Set<String> {
        var counted: [String: Int] = [:]
        for (ssid, rssi) in signal where rssi >= Self.minimumRSSI {
            counted[ssid] = (sightings[ssid] ?? 0) + 1
        }
        sightings = counted
        return Set(counted.filter { $0.value >= Self.sightingsNeeded }.keys)
    }

    /// A move began: the cooldown starts, whether or not it works.
    mutating func moved(at now: Date) {
        lastMoveAt = now
        forget()
    }

    /// The Mac left the network the sightings were counted on, or Wi-Fi
    /// dropped: count again from nothing.
    mutating func forget() {
        countingOn = nil
        sightings = [:]
    }
}

/// Decides when to move the Mac from a lower hotspot on the priority list
/// to a higher one that is back in range: you walk back to the car with
/// the phone while the Mac is on the tablet you left in it.
struct SwitchUpMachine: Sendable, Equatable {
    private(set) var counter = SightingCounter()
    var sightings: [String: Int] { counter.sightings }

    /// The hotspots above `current` to scan for, highest first. Empty
    /// when there is nothing to move to: the Mac is on no network, on one
    /// not on the list, or on the top hotspot, or a move is cooling down.
    mutating func candidates(current: String?, hotspots: [String], at now: Date) -> [String] {
        guard let current, let rank = hotspots.firstIndex(of: current), rank > 0 else {
            forget()
            return []
        }
        guard counter.begin(on: current, at: now) else { return [] }
        return Array(hotspots[..<rank])
    }

    /// A scan for `candidates` found `signal`. Returns the hotspot to move
    /// to: the highest one seen enough.
    mutating func scanned(_ signal: [String: Int], candidates: [String]) -> String? {
        let seen = counter.count(signal.filter { candidates.contains($0.key) })
        return candidates.first { seen.contains($0) }
    }

    mutating func moving(at now: Date) { counter.moved(at: now) }
    mutating func forget() { counter.forget() }
}

/// Decides when to hand the Mac back from a hotspot Insomnia joined to a
/// saved Wi-Fi network in range again: you get home with the Mac still on
/// the phone. Any network macOS knows counts, except the hotspots on the
/// list. Insomnia has no password for it, so the hand-back only leaves
/// the hotspot and macOS's auto-join rejoins the saved network (measured
/// on macOS 27: 14 s).
struct HandBackMachine: Sendable, Equatable {
    /// Seconds the failover holds its joins after a hand-back while
    /// macOS rejoins the saved network.
    static let grace: TimeInterval = 30

    private(set) var counter = SightingCounter()
    var sightings: [String: Int] { counter.sightings }

    /// Whether to scan for saved networks: the Mac is on `current`, the
    /// hotspot Insomnia joined (`joined`), and no hand-back is cooling
    /// down. A hotspot joined by hand, or by macOS, is left alone.
    mutating func due(current: String?, joined: String?, at now: Date) -> Bool {
        guard let current, let joined, HotspotSSID.matches(current, joined) else {
            forget()
            return false
        }
        return counter.begin(on: current, at: now)
    }

    /// A scan found `signal` among the saved networks. Returns the one to
    /// hand back to: the strongest seen enough.
    mutating func scanned(_ signal: [String: Int]) -> String? {
        counter.count(signal).max { (signal[$0]!, $1) < (signal[$1]!, $0) }
    }

    mutating func handingBack(at now: Date) { counter.moved(at: now) }
    mutating func forget() { counter.forget() }
}

// MARK: - networksetup parsing

enum HardwarePortsParser {
    /// Device name of the Wi-Fi port in `networksetup -listallhardwareports`
    /// output, e.g. "en0".
    static func wifiInterface(from output: String) -> String? {
        var currentIsWifi = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                let name = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces)
                currentIsWifi = name == "Wi-Fi" || name == "AirPort" || name.lowercased().contains("wi-fi")
            } else if line.hasPrefix("Device:"), currentIsWifi {
                let dev = line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                if !dev.isEmpty { return dev }
            }
        }
        return nil
    }

    /// SSID from `networksetup -getairportnetwork en0`
    /// ("Current Wi-Fi Network: Foo"), nil when not associated.
    static func ssid(fromGetAirportNetwork output: String) -> String? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = line.range(of: "Current Wi-Fi Network:") else { return nil }
        let ssid = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return ssid.isEmpty ? nil : ssid
    }
}

// MARK: - Keychain

/// Synchronous: a call can wait on a keychain dialog for as long as the
/// user leaves it open. The app makes these calls only on `KeychainQueue`.
protocol KeychainStoring: Sendable {
    func get(service: String, account: String) throws -> String?
    func set(service: String, account: String, value: String) throws
    func delete(service: String, account: String) throws
}

/// Runs the app's keychain calls one at a time on a thread of their own.
/// A save can wait on a keychain dialog until the user answers it; on the
/// main actor that wait would hold up the battery floor, the deadline
/// timer and End. The prompt switch is process-wide, so a read that turns
/// prompts off must not run while a save has them on: one serial queue
/// for every call keeps them apart. A dispatch queue rather than an
/// actor, so a call left waiting on a dialog holds this queue's thread
/// and not one of the shared pool's.
final class KeychainQueue: Sendable {
    /// The one the app uses, for the failover's reads and Settings' saves.
    static let shared = KeychainQueue()

    private let queue = DispatchQueue(label: "com.kgarg.insomnia.keychain")

    init() {}

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }
}

struct KeychainError: Error, LocalizedError, Sendable {
    let status: OSStatus
    var errorDescription: String? {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "keychain: \(msg)"
    }

    /// The item is there but macOS would have to show a keychain prompt to
    /// hand it over, and none was allowed. Measured on a throwaway keychain:
    /// an item whose access list names another build (errSecAuthFailed), a
    /// locked keychain (errSecAuthFailed too), and a delete of another
    /// build's item (errSecInvalidOwnerEdit).
    var isUnreadableWithoutPrompt: Bool {
        status == errSecAuthFailed || status == errSecInteractionNotAllowed || status == errSecInvalidOwnerEdit
    }

    var problem: HotspotPasswordProblem {
        isUnreadableWithoutPrompt ? .unreadable : .error(errorDescription ?? "OSStatus \(status)")
    }
}

/// The configured hotspot SSID as the keychain account: what the failover
/// joins and Settings saves under. One rule for both, so a check that the
/// SSID is still the same after a keychain wait compares like with like.
enum HotspotSSID {
    static func normalized(_ configured: String) -> String {
        configured.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// iOS names a device, and so its hotspot, with the curly apostrophe
    /// (U+2019), while a name typed on a Mac usually has the straight one.
    /// Folded, the two spellings compare equal.
    static func folded(_ name: String) -> String {
        String(normalized(name).map { curly.contains($0) ? "'" : $0 })
    }

    /// The same hotspot, whichever apostrophe each name uses.
    static func matches(_ a: String, _ b: String) -> Bool {
        folded(a) == folded(b)
    }

    /// Whether `names` has `name`, whichever apostrophe.
    static func any(of names: [String], matches name: String) -> Bool {
        names.contains { matches($0, name) }
    }

    /// The name with its apostrophes swapped for the other kind, or nil
    /// when it has none: a scan must name the network byte for byte.
    static func otherApostrophe(_ name: String) -> String? {
        if name.contains(where: { curly.contains($0) }) {
            return folded(name)
        }
        guard name.contains("'") else { return nil }
        return name.replacingOccurrences(of: "'", with: "\u{2019}")
    }

    private static let curly: Set<Character> = ["\u{2019}", "\u{2018}", "\u{02BC}"]
}

/// Why the failover has no hotspot password to join with. Shown in the
/// menu, in Settings and in one notification per outage; the join is never
/// skipped without one of these being surfaced.
enum HotspotPasswordProblem: Equatable, Sendable {
    /// No keychain item for the configured SSID.
    case missing
    /// The item exists but this build of Insomnia may not read it without a
    /// keychain prompt: it was saved by another build (an ad-hoc signature
    /// changes on every install), or the login keychain is locked.
    case unreadable
    /// Any other keychain failure.
    case error(String)

    /// What a failed keychain read means for the join.
    init(_ error: any Error) {
        self = (error as? KeychainError)?.problem ?? .error(error.localizedDescription)
    }

    /// One sentence for the notification body and the Settings notice.
    var explanation: String {
        switch self {
        case .missing:
            "No hotspot password is saved. Enter it in Settings."
        case .unreadable:
            "This build of Insomnia can't read the saved hotspot password (it was saved by another build, or the login keychain is locked). Enter it again in Settings."
        case let .error(message):
            "The hotspot password can't be read: \(message)"
        }
    }

    /// The right-click menu's warning line.
    var menuLine: String { menuLine(naming: nil) }

    /// The same for one hotspot of several (`ssid`), which says which one.
    func menuLine(naming ssid: String?) -> String {
        let subject = ssid.map { "Password for hotspot \"\($0)\"" } ?? "Hotspot password"
        return switch self {
        case .missing:
            "\u{26A0} \(subject) not saved: enter it in Settings"
        case .unreadable:
            "\u{26A0} \(subject) unreadable by this build: enter it again in Settings"
        case let .error(message):
            "\u{26A0} \(subject) unreadable: \(message)"
        }
    }

    /// Under a hotspot in the priority list in Settings.
    var listNotice: String {
        switch self {
        case .missing:
            "No password saved. Enter this name and its password below."
        case .unreadable:
            "This build of Insomnia can't read the saved password: it was saved by another build, or the login keychain is locked. Enter this name and its password below."
        case let .error(message):
            "The saved password can't be read: \(message)"
        }
    }

    /// Under the password field in Settings. A missing item needs no notice
    /// there: the field is empty.
    var settingsNotice: String? {
        switch self {
        case .missing:
            nil
        case .unreadable:
            "This build of Insomnia can't read the saved password: it was saved by another build, or the login keychain is locked. Enter it again and save. macOS may ask you to allow Insomnia to replace the old item."
        case let .error(message):
            "The saved password can't be read: \(message)"
        }
    }
}

/// A problem the failover reported, with the hotspot SSID it read for.
/// The menu and Settings show it only while that hotspot is the one
/// configured: after an SSID edit it is about an item no join reads.
struct HotspotPasswordReport: Equatable, Sendable {
    let ssid: String
    let problem: HotspotPasswordProblem

    /// The problem, if this report is about `configuredSSID`.
    func problem(for configuredSSID: String) -> HotspotPasswordProblem? {
        problem(among: [configuredSSID])
    }

    /// The problem, if this report is about one of `configuredSSIDs`, the
    /// hotspots an outage tries now (`Config.hotspotsToJoin`).
    func problem(among configuredSSIDs: [String]) -> HotspotPasswordProblem? {
        configuredSSIDs.contains { HotspotSSID.normalized($0) == ssid } ? problem : nil
    }

    /// The right-click menu's line while `config` is the one in use, or
    /// nil when the report is about a hotspot no longer configured. With
    /// several hotspots configured the line names this one.
    func menuLine(for config: Config) -> String? {
        let hotspots = config.hotspotsToJoin
        guard let problem = problem(among: hotspots) else { return nil }
        return problem.menuLine(naming: hotspots.count > 1 ? ssid : nil)
    }

    /// Whether the report still stands after a save or clear in Settings
    /// made `change`. A report about either item the save wrote or removed
    /// is out of date. The one report that stands is about the hotspot
    /// configured now, when the save touched neither of its items: it
    /// stored for an SSID edited away while it waited, and the window had
    /// not loaded the configured one.
    func stands(after change: HotspotPasswordChange, configuredSSID: String) -> Bool {
        stands(after: change, configuredSSIDs: [configuredSSID])
    }

    /// The same with several hotspots configured: the report stands while
    /// it is about one of them and the save touched neither of its items.
    func stands(after change: HotspotPasswordChange, configuredSSIDs: [String]) -> Bool {
        problem(among: configuredSSIDs) != nil && !change.touches(ssid)
    }
}

/// The keychain items a save or clear in Settings changed: the one it
/// stored or cleared for `ssid`, read when it began, and the one it
/// removed for `removed`, the SSID the window had loaded, when the SSID
/// was edited since the load.
struct HotspotPasswordChange: Equatable, Sendable {
    let ssid: String
    let removed: String?

    init(ssid: String, removed: String? = nil) {
        self.ssid = ssid
        self.removed = removed
    }

    /// Whether the save wrote or removed the item for `ssid`.
    func touches(_ ssid: String) -> Bool {
        ssid == self.ssid || ssid == removed
    }
}

/// The file-based keychain calls this store needs that the SDK marks
/// deprecated since macOS 10.10 but still ships: the process-wide prompt
/// switch, the per-item access list and the keychain an item lives in.
/// Resolved by name, like the DisplayServices calls, so the build stays
/// warning-free. They are public exports of Security.framework.
enum LegacyKeychain {
    private typealias SetInteraction = @convention(c) (UInt8) -> OSStatus
    private typealias GetInteraction = @convention(c) (UnsafeMutablePointer<UInt8>) -> OSStatus
    private typealias AccessCreate = @convention(c) (CFString, CFArray?, UnsafeMutablePointer<Unmanaged<SecAccess>?>) -> OSStatus
    private typealias ItemCopyKeychain = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<Unmanaged<SecKeychain>?>) -> OSStatus
    private typealias TrustedApplicationCreate = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Unmanaged<SecTrustedApplication>?>) -> OSStatus
    private typealias GetStatus = @convention(c) (SecKeychain?, UnsafeMutablePointer<UInt32>) -> OSStatus
    private typealias Unlock = @convention(c) (SecKeychain?, UInt32, UnsafeRawPointer?, UInt8) -> OSStatus

    private static func symbol<T>(_ name: String) throws -> T {
        guard let handle = dlopen(nil, RTLD_LAZY), let pointer = dlsym(handle, name) else {
            throw KeychainError(status: errSecUnimplemented)
        }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// The read and the write behind the process-wide prompt switch, as a
    /// seam: the app uses Security's pair, tests pass ones that fail or
    /// record.
    struct PromptSwitch: Sendable {
        /// The call's status and the current setting.
        let read: @Sendable () -> (OSStatus, Bool)
        let write: @Sendable (Bool) -> OSStatus

        static func system() throws -> PromptSwitch {
            let set: SetInteraction = try symbol("SecKeychainSetUserInteractionAllowed")
            let get: GetInteraction = try symbol("SecKeychainGetUserInteractionAllowed")
            return PromptSwitch(
                read: {
                    var state: UInt8 = 1
                    let status = get(&state)
                    return (status, state != 0)
                },
                write: { set($0 ? 1 : 0) }
            )
        }
    }

    /// Runs `body` with keychain prompts allowed or forbidden for this
    /// process and puts the previous setting back. With prompts forbidden an
    /// operation that would need one fails instead (see
    /// `KeychainError.isUnreadableWithoutPrompt`). Per-query keys such as
    /// kSecUseAuthenticationUI only govern the data protection keychain;
    /// this switch is what the file-based login keychain honours. A switch
    /// that cannot be read or written stops the call before `body` runs:
    /// an unknown setting could mean a prompt during an outage.
    static func withPrompts<T>(_ allowed: Bool, using prompts: PromptSwitch? = nil, _ body: () throws -> T) throws -> T {
        let prompts = try prompts ?? PromptSwitch.system()
        let (readStatus, previous) = prompts.read()
        guard readStatus == errSecSuccess else { throw KeychainError(status: readStatus) }
        let writeStatus = prompts.write(allowed)
        guard writeStatus == errSecSuccess else { throw KeychainError(status: writeStatus) }
        defer {
            let restored = prompts.write(previous)
            if restored != errSecSuccess {
                Log.error("keychain prompt switch not put back: OSStatus \(restored)")
            }
        }
        return try body()
    }

    /// Whether this process may currently raise keychain prompts.
    static func promptsAllowed() throws -> Bool {
        let (status, allowed) = try PromptSwitch.system().read()
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return allowed
    }

    /// The keychain file an item lives in.
    static func keychain(of item: CFTypeRef) throws -> SecKeychain {
        let copy: ItemCopyKeychain = try symbol("SecKeychainItemCopyKeychain")
        var keychain: Unmanaged<SecKeychain>?
        let status = copy(Unmanaged.passUnretained(item).toOpaque(), &keychain)
        guard status == errSecSuccess, let keychain else { throw KeychainError(status: status) }
        return keychain.takeRetainedValue()
    }

    /// Whether `keychain` (nil: the default keychain) is locked. Only reads
    /// its status, so no prompt.
    static func isLocked(_ keychain: SecKeychain?) throws -> Bool {
        let get: GetStatus = try symbol("SecKeychainGetStatus")
        var status: UInt32 = 0
        let result = get(keychain, &status)
        guard result == errSecSuccess else { throw KeychainError(status: result) }
        // kSecUnlockStateStatus
        return status & 1 == 0
    }

    /// Unlocks `keychain` (nil: the default keychain) by asking the user for
    /// its password, if prompts are allowed; otherwise it fails.
    static func unlock(_ keychain: SecKeychain?) throws {
        let unlock: Unlock = try symbol("SecKeychainUnlock")
        let result = unlock(keychain, 0, nil, 0)
        guard result == errSecSuccess else { throw KeychainError(status: result) }
    }

    /// This process's code as a trusted application. Under ad-hoc signing
    /// its designated requirement is the build's cdhash, so an access list
    /// naming it trusts exactly this build.
    static func thisApplication() throws -> SecTrustedApplication {
        let create: TrustedApplicationCreate = try symbol("SecTrustedApplicationCreateFromPath")
        var application: Unmanaged<SecTrustedApplication>?
        let status = create(nil, &application)
        guard status == errSecSuccess, let application else { throw KeychainError(status: status) }
        return application.takeRetainedValue()
    }

    /// An access list that lets `applications` use the item without a
    /// prompt and makes everyone else ask. `descriptor` is what that prompt
    /// names. An empty list trusts nobody.
    static func access(descriptor: String, trusting applications: [SecTrustedApplication]) throws -> SecAccess {
        let create: AccessCreate = try symbol("SecAccessCreate")
        var access: Unmanaged<SecAccess>?
        let status = create(descriptor as CFString, applications as CFArray, &access)
        guard status == errSecSuccess, let access else { throw KeychainError(status: status) }
        return access.takeRetainedValue()
    }
}

/// The SecItem calls behind `KeychainStore`, plus the lookup of the
/// keychain file an item lives in, as a seam. The app uses Security's;
/// tests script the status codes and record the call order and the prompt
/// switch at each call, which covers the paths that need a prompt in real
/// life (another build's item, a locked keychain) without raising one.
protocol KeychainItemCalls: Sendable {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
    func add(_ attributes: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
    /// The keychain file holding `item`, a reference from `copyMatching`.
    func keychain(of item: CFTypeRef) -> (OSStatus, SecKeychain?)
    /// Whether that keychain is locked.
    func isLocked(_ keychain: SecKeychain?) -> (OSStatus, Bool)
    /// Unlocks it, with the system's password prompt when prompts are
    /// allowed.
    func unlock(_ keychain: SecKeychain?) -> OSStatus
}

struct SecurityItemCalls: KeychainItemCalls {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        SecItemAdd(attributes, nil)
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }

    func keychain(of item: CFTypeRef) -> (OSStatus, SecKeychain?) {
        do {
            return (errSecSuccess, try LegacyKeychain.keychain(of: item))
        } catch let error as KeychainError {
            return (error.status, nil)
        } catch {
            return (errSecUnimplemented, nil)
        }
    }

    func isLocked(_ keychain: SecKeychain?) -> (OSStatus, Bool) {
        do {
            return (errSecSuccess, try LegacyKeychain.isLocked(keychain))
        } catch let error as KeychainError {
            return (error.status, false)
        } catch {
            return (errSecUnimplemented, false)
        }
    }

    func unlock(_ keychain: SecKeychain?) -> OSStatus {
        do {
            try LegacyKeychain.unlock(keychain)
            return errSecSuccess
        } catch let error as KeychainError {
            return error.status
        } catch {
            return errSecUnimplemented
        }
    }
}

/// Login keychain generic password, service `insomnia-hotspot`, account =
/// SSID. The item's access list names only the Insomnia build that saved it
/// (`LegacyKeychain.thisApplication()`), and every read runs with keychain
/// prompts forbidden, so the failover never raises a dialog: an item this
/// build may not open fails with `KeychainError.isUnreadableWithoutPrompt`
/// and the caller surfaces `HotspotPasswordProblem.unreadable`.
///
/// A save writes to the keychain file that holds the item reads find,
/// which need not be the default keychain. A locked keychain hides this
/// build's items as well as another build's, so a save that finds the
/// item unreadable first unlocks that keychain and starts over. An item
/// this build can read already names this build in its access list, so
/// only its value changes, in place. An item it still cannot read is
/// another build's and needs a new access list, which the file-based
/// keychain changes only by replacing the item: the new password goes
/// beside it under `replacementService(for:)`, the old item is deleted,
/// and the new one is renamed into its place. `get` reads only the item
/// itself, never a replacement, so it cannot return a password some other
/// save left under that name, in this keychain or another one on the
/// search list. The cost is one rare state: a save stopped between the
/// delete and the rename leaves the new password where reads do not look,
/// the password reads as missing, and the user enters it again; that save
/// then finishes the swap. The prompts a save may raise, the unlock and
/// the delete of another build's item, are allowed because a save or clear
/// is the user's own click in Settings. Every call can wait on such a
/// prompt, so the app runs them on `KeychainQueue`.
///
/// `kSecAttrAccessible` (this device only, when unlocked) is not set: the
/// file-based login keychain accepts and drops it (measured on a throwaway
/// keychain, the attribute does not read back), and the data protection
/// keychain that honours it needs a keychain access group entitlement,
/// which needs a team id.
struct KeychainStore: KeychainStoring, @unchecked Sendable {
    static let service = "insomnia-hotspot"
    /// What the keychain prompt names if another program asks for the item.
    static let accessDescriptor = "Insomnia hotspot password"

    /// Where a save keeps the new password while it replaces an item this
    /// build cannot read.
    static func replacementService(for service: String) -> String {
        "\(service).replacing"
    }

    /// The keychains searched, in order; nil is the user's search list.
    /// Tests pass throwaway keychain files; the app passes nothing. CF
    /// references the store never mutates, hence the unchecked Sendable.
    private let searchList: [SecKeychain]?
    /// Where an item with no existing copy is added; nil is the default
    /// keychain.
    private let newItems: SecKeychain?
    private let calls: any KeychainItemCalls
    /// nil is Security's process-wide switch. Tests against a throwaway
    /// keychain pass one that refuses to allow prompts.
    private let prompts: LegacyKeychain.PromptSwitch?

    init(
        keychain: SecKeychain? = nil,
        calls: any KeychainItemCalls = SecurityItemCalls(),
        prompts: LegacyKeychain.PromptSwitch? = nil
    ) {
        self.init(searchList: keychain.map { [$0] }, newItems: keychain, calls: calls, prompts: prompts)
    }

    init(
        searchList: [SecKeychain]?,
        newItems: SecKeychain?,
        calls: any KeychainItemCalls = SecurityItemCalls(),
        prompts: LegacyKeychain.PromptSwitch? = nil
    ) {
        self.searchList = searchList
        self.newItems = newItems
        self.calls = calls
        self.prompts = prompts
    }

    /// The item itself only. A replacement is never read: which save left
    /// it, and whether that save finished, is not known.
    func get(service: String, account: String) throws -> String? {
        let (status, data) = try read(service: service, account: account)
        if status == errSecSuccess { return data.map { String(decoding: $0, as: UTF8.self) } }
        if status == errSecItemNotFound { return nil }
        throw KeychainError(status: status)
    }

    func set(service: String, account: String, value: String) throws {
        try set(service: service, account: account, data: Data(value.utf8), unlocked: false)
    }

    /// `unlocked`: this save has already unlocked the keychain once.
    private func set(service: String, account: String, data: Data, unlocked: Bool) throws {
        let (status, _) = try read(service: service, account: account)
        switch status {
        case errSecItemNotFound:
            try add(service: service, account: account, data: data, label: service, to: newItems)
        case errSecSuccess:
            // Readable without a prompt, so the access list already names
            // this build: one in-place change of the value.
            let holder = try keychainHolding(service: service, account: account)
            try updateValue(service: service, account: account, data: data, in: holder)
        default:
            guard KeychainError(status: status).isUnreadableWithoutPrompt else { throw KeychainError(status: status) }
            let holder = try keychainHolding(service: service, account: account)
            if try isLocked(holder) {
                // Locked, every item reads as unreadable, this build's own
                // included. Unlock (the user's Save allows the prompt) and
                // decide again by what reads return then.
                guard !unlocked else { throw KeychainError(status: errSecInteractionNotAllowed) }
                let result = try withPrompts(true) { calls.unlock(holder) }
                guard result == errSecSuccess else { throw KeychainError(status: result) }
                try set(service: service, account: account, data: data, unlocked: true)
                return
            }
            try replaceUnreadable(service: service, account: account, data: data, in: holder)
            return
        }
        // Reads never use a replacement left by an interrupted save; remove
        // it if that needs no prompt.
        let leftover = query(service: Self.replacementService(for: service), account: account) as CFDictionary
        _ = try? withPrompts(false) { calls.delete(leftover) }
    }

    func delete(service: String, account: String) throws {
        try deleteItem(service: service, account: account, in: nil)
        try deleteItem(service: Self.replacementService(for: service), account: account, in: nil)
    }

    /// Another build's item, in an unlocked keychain. Until the old item
    /// is deleted, reads find it, unreadable as before; after the rename
    /// they find the new password. In between they find nothing, because
    /// `get` never reads the replacement. A replacement this build can
    /// read, left by a save that stopped short, has its value changed in
    /// place. One this build cannot read is another build's and is
    /// deleted before the add. A refused delete of the old item (the user
    /// declined the prompt) removes the replacement and keeps the old item.
    private func replaceUnreadable(service: String, account: String, data: Data, in holder: SecKeychain?) throws {
        let replacement = Self.replacementService(for: service)
        let (status, _) = try read(service: replacement, account: account, in: holder)
        switch status {
        case errSecSuccess:
            try updateValue(service: replacement, account: account, data: data, in: holder)
        case errSecItemNotFound:
            try add(service: replacement, account: account, data: data, label: service, to: holder)
        default:
            guard KeychainError(status: status).isUnreadableWithoutPrompt else { throw KeychainError(status: status) }
            // Only while the keychain is unlocked does unreadable mean
            // another build's. One that locked again since the check stops
            // the save here: the delete would ask to unlock it a second time.
            guard try !isLocked(holder) else { throw KeychainError(status: errSecInteractionNotAllowed) }
            try deleteItem(service: replacement, account: account, in: holder)
            try add(service: replacement, account: account, data: data, label: service, to: holder)
        }
        do {
            try deleteItem(service: service, account: account, in: holder)
        } catch {
            // This save wrote the replacement, so this build can delete it
            // without a prompt.
            let written = query(service: replacement, account: account, in: holder) as CFDictionary
            _ = try? withPrompts(false) { calls.delete(written) }
            throw error
        }
        let renamed = query(service: replacement, account: account, in: holder) as CFDictionary
        let changes = [kSecAttrService as String: service] as CFDictionary
        let renameStatus = try withPrompts(false) { calls.update(renamed, changes) }
        guard renameStatus == errSecSuccess else { throw KeychainError(status: renameStatus) }
    }

    /// One prompt-free, in-place change of an item's value; for items this
    /// build can read, whose access list already names it.
    private func updateValue(service: String, account: String, data: Data, in holder: SecKeychain?) throws {
        let query = self.query(service: service, account: account, in: holder) as CFDictionary
        let changes = [kSecValueData as String: data] as CFDictionary
        let status = try withPrompts(false) { calls.update(query, changes) }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func isLocked(_ holder: SecKeychain?) throws -> Bool {
        let (status, locked) = calls.isLocked(holder)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return locked
    }

    /// A prompt-free read of one item's value.
    private func read(service: String, account: String, in holder: SecKeychain? = nil) throws -> (OSStatus, Data?) {
        var query = self.query(service: service, account: account, in: holder)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = try withPrompts(false) { calls.copyMatching(query as CFDictionary, &item) }
        return (status, item as? Data)
    }

    /// The keychain file holding the item a read finds. Only a reference
    /// is asked for, which needs no prompt even for another build's item.
    private func keychainHolding(service: String, account: String) throws -> SecKeychain? {
        var query = self.query(service: service, account: account)
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = try withPrompts(false) { calls.copyMatching(query as CFDictionary, &item) }
        guard status == errSecSuccess, let item else {
            throw KeychainError(status: status == errSecSuccess ? errSecItemNotFound : status)
        }
        let (lookup, holder) = calls.keychain(of: item)
        guard lookup == errSecSuccess else { throw KeychainError(status: lookup) }
        return holder
    }

    /// Adds with this build on the access list. A locked keychain gets the
    /// unlock prompt, on the user's own click. `label`, what Keychain Access
    /// shows, is the item's real service, which a replacement keeps after
    /// the rename.
    private func add(service: String, account: String, data: Data, label: String, to keychain: SecKeychain?) throws {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: label,
            kSecValueData as String: data,
            kSecAttrAccess as String: try LegacyKeychain.access(
                descriptor: Self.accessDescriptor,
                trusting: [try LegacyKeychain.thisApplication()]
            ),
        ]
        if let keychain { attributes[kSecUseKeychain as String] = keychain }
        let item = attributes as CFDictionary
        var status = try withPrompts(false) { calls.add(item) }
        if KeychainError(status: status).isUnreadableWithoutPrompt {
            status = try withPrompts(true) { calls.add(item) }
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Deletes without a prompt, or with one for another build's item: this
    /// delete is always the user's own save or clear in Settings.
    private func deleteItem(service: String, account: String, in holder: SecKeychain?) throws {
        let query = self.query(service: service, account: account, in: holder) as CFDictionary
        var status = try withPrompts(false) { calls.delete(query) }
        if KeychainError(status: status).isUnreadableWithoutPrompt {
            status = try withPrompts(true) { calls.delete(query) }
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    /// `holder` narrows the search to the keychain that holds the item;
    /// otherwise the store's search list applies.
    private func query(service: String, account: String, in holder: SecKeychain? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let holder {
            query[kSecMatchSearchList as String] = [holder]
        } else if let searchList {
            query[kSecMatchSearchList as String] = searchList
        }
        return query
    }

    private func withPrompts<T>(_ allowed: Bool, _ body: () throws -> T) throws -> T {
        try LegacyKeychain.withPrompts(allowed, using: prompts, body)
    }
}

final class FakeKeychainStore: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var _unreadable: Set<String> = []
    private var _deletes: [String] = []
    /// Reads of these `service/account` keys fail the way another build's
    /// item does with prompts forbidden (errSecAuthFailed).
    var unreadable: Set<String> {
        get { lock.withLock { _unreadable } }
        set { lock.withLock { _unreadable = newValue } }
    }
    /// Every `service/account` deleted, in order.
    var deletes: [String] { lock.withLock { _deletes } }

    func get(service: String, account: String) throws -> String? {
        let key = "\(service)/\(account)"
        if unreadable.contains(key) { throw KeychainError(status: errSecAuthFailed) }
        return lock.withLock { items[key] }
    }
    func set(service: String, account: String, value: String) throws { lock.withLock { items["\(service)/\(account)"] = value } }
    func delete(service: String, account: String) throws {
        lock.withLock {
            _deletes.append("\(service)/\(account)")
            _ = items.removeValue(forKey: "\(service)/\(account)")
        }
    }
}

// MARK: - Driver

/// NWPathMonitor on Wi-Fi, one retry timer that exists only during an
/// outage, CoreWLAN for the join, handoffs.log, tmux nudge and a
/// notification on recovery. Active only while a session is active.
@MainActor
final class NetworkFailover {
    static let networksetup = "/usr/sbin/networksetup"

    /// Called after every recovery with the gap length.
    var onRecovered: ((TimeInterval) -> Void)?
    /// Called when the password report changes: set when a join is skipped
    /// for want of a readable password, nil once a read succeeds or the
    /// password is saved again.
    var onPasswordReport: ((HotspotPasswordReport?) -> Void)?

    private(set) var machine = FailoverMachine()
    private(set) var wifiInterface: String?
    private(set) var lastGap: TimeInterval?
    /// Why the last join was skipped before the join itself, if it was,
    /// and for which hotspot.
    private(set) var passwordReport: HotspotPasswordReport? {
        didSet { if passwordReport != oldValue { onPasswordReport?(passwordReport) } }
    }
    /// The hotspots whose skipped join this outage has notified, so the
    /// retries (every 5 to 30 s) do not repeat it. A hotspot configured
    /// during the outage is notified for itself. Cleared on recovery, so
    /// the next outage is notified again, and on stop and on a saved
    /// password.
    private var notifiedThisOutage: Set<String> = []

    private let paths: Paths
    private let keychain: any KeychainStoring
    private let keychainQueue: KeychainQueue
    private let nudge: TmuxNudge
    private let hotspotJoiner: any HotspotJoining
    private let scanner: any HotspotScanning
    private let waker: any HotspotWaking
    private let notifier: any Notifying
    private let configProvider: @MainActor () -> Config
    private let clock: @Sendable () -> Date

    private var monitor: NWPathMonitor?
    private(set) var retryTimer: Timer?
    private var generation = 0
    /// Bumped by `stop()`. Work that started under an older epoch (a
    /// recovery mid-nudge) stops issuing commands as soon as it notices.
    private var epoch = 0
    /// Bumped when an outage ends, by recovery or by `stop()`. A join, and
    /// the retry its timer tick queued after it, belong to the outage they
    /// started in: a join whose keychain read waited behind a save can
    /// finish after Wi-Fi came back, and then it must not move the
    /// recovered connection to the hotspot, report a problem, or start
    /// another retry timer.
    private var outage = 0
    /// Path/timer work spawned by the driver, cancelled by `stop()`.
    private var inflight: [UUID: Task<Void, Never>] = [:]
    /// When to move up the priority list. Reset by `stop()`.
    private(set) var switchUp = SwitchUpMachine()
    /// When to leave a hotspot for a saved Wi-Fi network. Reset by `stop()`.
    private(set) var handBack = HandBackMachine()
    /// The hotspot Insomnia joined last, the only one a hand-back leaves.
    /// Kept in joined-hotspot.json, so a restart or a new session knows the
    /// Mac is still on it. Cleared by a hand-back, and by a check that
    /// finds the Mac on a network that is not a listed hotspot.
    private(set) var joinedHotspot: String? {
        didSet { if joinedHotspot != oldValue { saveJoinedHotspot() } }
    }
    /// What each woken device handed over, by folded SSID, so a later join
    /// this session needs no wake and no saved password. Memory only,
    /// never written anywhere; cleared by `stop()`.
    private var handedOver: [String: HotspotCredentials] = [:]
    /// The saved network a hand-back left a hotspot for, and until when
    /// the failover's joins wait for macOS to rejoin it.
    private(set) var handingBack: (network: String, until: Date)?
    /// Saved networks macOS did not rejoin after a hand-back (auto-join
    /// off, a stale password): never handed back to again this session,
    /// so one cannot take the Mac offline every cooldown. Cleared by
    /// `stop()`.
    private(set) var refusedHandBacks: [String] = []
    /// Names the networks of the lines about where the Mac lands, made on
    /// first use. The hotspots on the list keep their names in the log.
    private lazy var tag = NetworkTag.load(paths)
    /// Seconds between hotspot checks during a session.
    static let hotspotCheckInterval: TimeInterval = 30
    /// Checks every `hotspotCheckInterval` for a higher hotspot and for a
    /// saved Wi-Fi network, only while the session runs with the priority
    /// list and either check on (`syncHotspotChecks`). A check with
    /// nothing to do costs one read of the current SSID and no scan.
    private(set) var hotspotCheckTimer: Timer?
    /// How often a woken hotspot is looked for, and how long to wait
    /// between looks: it can take a few seconds to come on the air.
    var wokenJoinTries = 3
    var wokenJoinWait: Duration = .seconds(3)
    /// A move up the list or a hand-back is under way. The failover's
    /// joins wait for it, so two never change the network at once.
    private(set) var changingNetwork = false

    init(
        paths: Paths,
        keychain: any KeychainStoring = KeychainStore(),
        keychainQueue: KeychainQueue = .shared,
        nudge: TmuxNudge = TmuxNudge(),
        hotspotJoiner: any HotspotJoining = CoreWLANHotspotJoiner(),
        scanner: any HotspotScanning = CoreWLANHotspotScanner(),
        waker: any HotspotWaking = NoHotspotWaker(),
        notifier: any Notifying,
        wifiInterface: String? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        config: @escaping @MainActor () -> Config
    ) {
        self.paths = paths
        self.keychain = keychain
        self.keychainQueue = keychainQueue
        self.nudge = nudge
        self.hotspotJoiner = hotspotJoiner
        self.scanner = scanner
        self.waker = waker
        self.notifier = notifier
        self.wifiInterface = wifiInterface
        self.clock = clock
        self.configProvider = config
        self.joinedHotspot = Self.loadJoinedHotspot(paths)
    }

    func start() async {
        guard monitor == nil else { return }
        let epoch = self.epoch
        await resolveInterface()
        // The record of the hotspot Insomnia joined outlives sessions, and
        // the Mac may have left that hotspot since: it decides the next
        // outage's first wait (`firstJoinDelay`).
        if joinedHotspot != nil, let iface = wifiInterface {
            observe(await scanner.currentSSID(interfaceName: iface).map(HotspotSSID.normalized))
        }
        // stop() may have run while networksetup was being awaited.
        guard !Task.isCancelled, self.epoch == epoch else { return }
        let m = NWPathMonitor(requiredInterfaceType: .wifi)
        let id = ObjectIdentifier(m)
        m.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                // An update queued before stop() must not revive the driver.
                guard let self, let current = self.monitor, ObjectIdentifier(current) == id else { return }
                self.handlePath(satisfied: satisfied)
            }
        }
        m.start(queue: .main)
        monitor = m
        syncHotspotChecks()
        Log.info("network failover started (wifi \(wifiInterface ?? "unresolved"))")
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        cancelTimer()
        hotspotCheckTimer?.invalidate()
        hotspotCheckTimer = nil
        for task in inflight.values { task.cancel() }
        inflight.removeAll()
        epoch += 1
        outage += 1
        machine = FailoverMachine()
        switchUp = SwitchUpMachine()
        handBack = HandBackMachine()
        // `joinedHotspot` stays: the next session, after a restart too, is
        // still on the hotspot Insomnia joined.
        handingBack = nil
        refusedHandBacks = []
        handedOver = [:]
        changingNetwork = false
        // The session is over: the menu line about the password goes with it.
        passwordReport = nil
        notifiedThisOutage = []
    }

    /// Settings saved or cleared the password and made `change`: forget
    /// the report unless it still stands (`HotspotPasswordReport.stands`),
    /// so the menu line goes, and forget the notifications of every other
    /// hotspot, so a problem that comes back is notified afresh.
    func passwordChanged(_ change: HotspotPasswordChange, configuredSSID: String) {
        passwordChanged(change, configuredSSIDs: [configuredSSID])
    }

    /// The same with several hotspots configured (`Config.hotspotsToJoin`).
    func passwordChanged(_ change: HotspotPasswordChange, configuredSSIDs: [String]) {
        if passwordReport?.stands(after: change, configuredSSIDs: configuredSSIDs) != true {
            passwordReport = nil
        }
        notifiedThisOutage = notifiedThisOutage.filter { $0 == passwordReport?.ssid }
    }

    /// Current SSID via `networksetup -getairportnetwork`; nil when unknown.
    func currentSSID() async -> String? {
        if wifiInterface == nil { await resolveInterface() }
        guard let iface = wifiInterface else { return nil }
        do {
            let r = try await Shell.run(Self.networksetup, ["-getairportnetwork", iface], timeout: 5)
            return HardwarePortsParser.ssid(fromGetAirportNetwork: r.stdout)
        } catch {
            Log.error("getairportnetwork failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Private

    private func resolveInterface() async {
        guard wifiInterface == nil else { return }
        do {
            let r = try await Shell.run(Self.networksetup, ["-listallhardwareports"], timeout: 5)
            wifiInterface = HardwarePortsParser.wifiInterface(from: r.stdout)
            if wifiInterface == nil {
                Log.error("could not find a Wi-Fi port in networksetup -listallhardwareports")
            } else {
                Log.info("wifi interface \(wifiInterface!)")
            }
        } catch {
            Log.error("listallhardwareports failed: \(error.localizedDescription)")
        }
    }

    /// What the NWPathMonitor calls. Internal so tests can exercise the
    /// driver-owned task without a monitor.
    func handlePath(satisfied: Bool) {
        track { [weak self] in await self?.process(satisfied: satisfied) }
    }

    /// Feed one path update through the machine and apply its outputs.
    /// Public so tests can drive the driver without an NWPathMonitor.
    func simulate(satisfied: Bool) async {
        await process(satisfied: satisfied)
    }

    /// Runs `operation` in a task that `stop()` cancels.
    @discardableResult
    private func track(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.inflight[id] = nil
        }
        inflight[id] = task
        return task
    }

    private func process(satisfied: Bool) async {
        guard !Task.isCancelled else { return }
        let now = clock()
        let delay = firstJoinDelay()
        let outputs = satisfied ? machine.pathSatisfied(at: now) : machine.pathUnsatisfied(at: now, delay: delay)
        if outputs.isEmpty { return }
        if !satisfied {
            Log.info(delay > FailoverMachine.initialDelay
                ? "wifi path unsatisfied; macOS has \(Int(delay)) s to rejoin a network before a hotspot is woken"
                : "wifi path unsatisfied")
            switchUp.forget()
        }
        await apply(outputs)
    }

    /// How long an outage waits for its first join. Off the hotspot
    /// Insomnia joined, macOS may well rejoin the network it dropped by
    /// itself, and a join meanwhile would fight it ("Resource busy") and
    /// wake a hotspot for nothing: the outage waits longer then, unless
    /// Settings asks for the aggressive join.
    private func firstJoinDelay() -> TimeInterval {
        configProvider().aggressiveHotspotJoin || joinedHotspot != nil ? FailoverMachine.initialDelay : FailoverMachine.patientDelay
    }

    /// What the retry timer calls. Internal so tests can exercise the
    /// driver-owned join/retry task without waiting for a real timer; the
    /// task is returned so a test can await the tick it fired.
    @discardableResult
    func fireTimer() -> Task<Void, Never> {
        retryTimer = nil
        let outputs = machine.timerFired(at: clock())
        return track { [weak self] in await self?.apply(outputs) }
    }

    private func apply(_ outputs: [FailoverMachine.Output]) async {
        let epoch = self.epoch
        let outage = self.outage
        for o in outputs {
            // A join or recovery above may have been awaited across stop():
            // the machine is reset by then, so the remaining outputs (a retry
            // timer, most importantly) belong to a session that is gone.
            guard !Task.isCancelled, self.epoch == epoch else {
                Log.info("network failover: dropping queued outputs after stop")
                return
            }
            // The same for a join awaited across a recovery: its retry
            // belongs to the outage that just ended.
            guard self.outage == outage else {
                Log.info("network failover: dropping queued outputs after recovery")
                return
            }
            switch o {
            case let .scheduleRetry(after):
                schedule(after: after)
            case .joinHotspot:
                await joinHotspot()
            case let .recovered(start, gap):
                self.outage += 1
                cancelTimer()
                notifiedThisOutage = []
                await recovered(start: start, gap: gap)
            }
        }
    }

    private func schedule(after: TimeInterval) {
        cancelTimer()
        generation += 1
        let gen = generation
        let t = Timer(timeInterval: after, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.fireTimer()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
    }

    private func cancelTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
        generation += 1
    }

    // MARK: Switching up and handing back

    /// Starts the check timer when the driver runs with the priority list
    /// and switch-up or the hand-back on, and stops it otherwise, so a
    /// session without them has no timer at all. Called at start and when
    /// Settings changes any of the toggles.
    func syncHotspotChecks() {
        let config = configProvider()
        let wanted = monitor != nil && config.hotspotPriorityEnabled && (config.hotspotSwitchUp || config.hotspotReturnToWiFi)
        guard wanted != (hotspotCheckTimer != nil) else { return }
        guard wanted else {
            hotspotCheckTimer?.invalidate()
            hotspotCheckTimer = nil
            switchUp.forget()
            handBack.forget()
            return
        }
        let t = Timer(timeInterval: NetworkFailover.hotspotCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHotspots() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        hotspotCheckTimer = t
    }

    /// What the check timer calls. Internal so tests can run a check
    /// without waiting for the timer; the task is returned so a test can
    /// await it.
    @discardableResult
    func checkHotspots() -> Task<Void, Never> {
        track { [weak self] in await self?.checkHotspotsIfDue() }
    }

    /// One check. On the hotspot Insomnia joined, scan for saved Wi-Fi
    /// networks and hand back to the one `HandBackMachine` has seen
    /// enough of: a saved network beats any hotspot. Otherwise, on a lower
    /// hotspot of the priority list, scan for the higher ones and move to
    /// the highest one `SwitchUpMachine` has seen enough of. Nothing while
    /// Wi-Fi is down: the failover owns an outage.
    private func checkHotspotsIfDue() async {
        let config = configProvider()
        let climbing = config.hotspotPriorityEnabled && config.hotspotSwitchUp
        let leaving = config.hotspotPriorityEnabled && config.hotspotReturnToWiFi
        if !climbing { switchUp.forget() }
        if !leaving { handBack.forget() }
        guard climbing || leaving else { return }
        guard !changingNetwork, !machine.inOutage, let iface = wifiInterface else { return }
        // A hand-back that macOS answered without an outage is over.
        if let h = handingBack, clock() >= h.until { handingBack = nil }
        let epoch = self.epoch
        let outage = self.outage
        func stillDue() -> Bool {
            !Task.isCancelled && self.epoch == epoch && self.outage == outage && !machine.inOutage && !changingNetwork
        }
        let current = await scanner.currentSSID(interfaceName: iface).map(HotspotSSID.normalized)
        guard stillDue() else { return }
        let hotspots = configProvider().hotspotsToJoin
        observe(current)
        if leaving, let current, handBack.due(current: current, joined: joinedHotspot, at: clock()) {
            do {
                let saved = try await scanner.savedSignal(excluding: hotspots + refusedHandBacks, interfaceName: iface)
                guard stillDue() else { return }
                if let network = handBack.scanned(saved) {
                    await handBack(from: current, to: network, signal: saved[network] ?? 0, interfaceName: iface)
                    return
                }
            } catch {
                Log.error("saved Wi-Fi scan failed: \(error.localizedDescription)")
            }
        }
        guard climbing else { return }
        // The list's own spelling of the network the Mac is on: a woken
        // device hands over its name with the curly apostrophe.
        let listed = current.flatMap { current in hotspots.first { HotspotSSID.matches($0, current) } }
        let candidates = switchUp.candidates(current: listed, hotspots: hotspots, at: clock())
        guard let current = listed, !candidates.isEmpty else { return }
        let seen: [String: Int]
        do {
            seen = try await scanner.signal(of: candidates, interfaceName: iface)
        } catch {
            Log.error("hotspot switch-up scan failed: \(error.localizedDescription)")
            return
        }
        guard stillDue() else { return }
        guard let target = switchUp.scanned(seen, candidates: candidates) else { return }
        await move(from: current, to: target, interfaceName: iface)
    }

    /// Moves from `current` to the higher hotspot `target`. Both passwords
    /// are found first, while the Mac is still online (`credentials`):
    /// `target` is woken for its own. The join scans for
    /// `target` before it leaves `current`, so a hotspot gone again by
    /// then costs nothing; one that refuses the join leaves the Mac on no
    /// network, and it goes straight back to `current` instead of waiting
    /// for the failover's first retry.
    private func move(from current: String, to target: String, interfaceName iface: String) async {
        changingNetwork = true
        switchUp.moving(at: clock())
        defer { changingNetwork = false }
        let epoch = self.epoch
        let hotspots = configProvider().hotspotsToJoin
        let place = { (ssid: String) in Self.place(of: ssid, in: hotspots) ?? "the hotspot" }
        let targetCredentials = await credentials(for: target, waking: true)
        let backCredentials = await credentials(for: current, waking: false)
        guard !Task.isCancelled, self.epoch == epoch, !machine.inOutage else { return }
        guard let targetCredentials else {
            Log.error("hotspot switch-up skipped: \(place(target)) did not wake, and no password for it is known")
            return
        }
        let configured = configProvider().hotspotsToJoin
        guard HotspotSSID.any(of: configured, matches: target), HotspotSSID.any(of: configured, matches: current) else {
            Log.info("hotspot switch-up dropped: the hotspots changed during the keychain read")
            return
        }
        Log.info("moving from \(place(current)) to \(place(target)) (\(target)), which is back in range")
        switch await join(targetCredentials, interfaceName: iface) {
        case .joined:
            Log.info("moved to hotspot \(target)")
            return
        case .notFound:
            Log.info("hotspot switch-up: the scan no longer finds \(target); staying on \(current)")
            return
        case let .failed(error):
            Log.error("hotspot switch-up to \(target) failed: \(error.localizedDescription)")
        }
        guard !Task.isCancelled, self.epoch == epoch else { return }
        // Still on a network (the join failed before leaving, or macOS
        // joined one): leave it be.
        guard await scanner.currentSSID(interfaceName: iface) == nil else { return }
        guard !Task.isCancelled, self.epoch == epoch else { return }
        // The device left is still on: woken again, it hands its password over.
        var back = backCredentials
        if back == nil {
            back = await credentials(for: current, waking: true)
            guard !Task.isCancelled, self.epoch == epoch else { return }
        }
        guard let back else {
            Log.error("hotspot switch-up: offline, and no password for \(place(current)) is known; the failover takes over")
            return
        }
        Log.info("hotspot switch-up: rejoining \(current)")
        switch await join(back, interfaceName: iface) {
        case .joined:
            break
        case .notFound:
            Log.error("hotspot switch-up: the scan no longer finds \(current); the failover takes over")
        case let .failed(error):
            Log.error("hotspot switch-up: rejoining \(current) failed: \(error.localizedDescription); the failover takes over")
        }
    }

    /// Leaves the hotspot `current` for the saved network `network`, which
    /// macOS rejoins by itself: Insomnia has no password for it. The
    /// failover's joins wait `HandBackMachine.grace` for that, then take
    /// over if the Mac is still on no network.
    private func handBack(from current: String, to network: String, signal: Int, interfaceName iface: String) async {
        changingNetwork = true
        handBack.handingBack(at: clock())
        defer { changingNetwork = false }
        Log.info("leaving hotspot \(current) for saved Wi-Fi \(tag(network)) (\(signal) dBm), which is back in range; macOS rejoins it")
        joinedHotspot = nil
        handingBack = (network, clock().addingTimeInterval(HandBackMachine.grace))
        do {
            try await hotspotJoiner.leave(interfaceName: iface)
        } catch {
            Log.error("leaving hotspot \(current) failed: \(error.localizedDescription)")
            handingBack = nil
            joinedHotspot = current
        }
    }

    /// One join attempt: the configured hotspots in priority order
    /// (`Config.hotspotsToJoin`), each read from the keychain and joined,
    /// until one joins. A hotspot whose password is missing or unreadable
    /// is reported and skipped, and so is one the scan does not find or
    /// that refuses the join, so the next one on the list gets its turn.
    /// A phone or tablet macOS sees over Bluetooth is woken first, since
    /// it keeps its hotspot off the air while nothing uses it, and joined
    /// with the network and password it hands over (`HotspotWaking`).
    /// Those nearby go ahead of the rest, in the order of the list. No
    /// Wi-Fi scan comes before the joins: one did, and every join right
    /// after it failed with "Resource busy".
    func joinHotspot() async {
        let hotspots = configProvider().hotspotsToJoin
        guard !hotspots.isEmpty else {
            Log.info("hotspot join skipped: no hotspot configured")
            return
        }
        guard let iface = wifiInterface else {
            Log.error("hotspot join skipped: no Wi-Fi interface")
            return
        }
        // A move or a hand-back is changing the network; the retry comes back.
        guard !changingNetwork else {
            Log.info("hotspot join skipped: a move or hand-back is under way")
            return
        }
        // A hand-back left the hotspot on purpose: give macOS its time to
        // rejoin the saved network. The retry comes back.
        if let h = handingBack {
            let left = h.until.timeIntervalSince(clock())
            guard left <= 0 else {
                Log.info("hotspot join held: macOS has \(Int(left.rounded(.up))) s more to rejoin \(tag(h.network))")
                return
            }
            Log.info("macOS did not rejoin \(tag(h.network)) within \(Int(HandBackMachine.grace)) s; joining a hotspot, and no more hand-backs to it this session")
            refusedHandBacks.append(h.network)
            handingBack = nil
        }
        let epoch = self.epoch
        let outage = self.outage
        let near = await waker.nearbyNames()
        guard !Task.isCancelled, self.epoch == epoch, self.outage == outage else {
            Log.info("hotspot join dropped: the session ended or Wi-Fi recovered during the Bluetooth look")
            return
        }
        let isNear = { (ssid: String) in HotspotSSID.any(of: near, matches: ssid) }
        let order = hotspots.filter(isNear) + hotspots.filter { !isNear($0) }
        if !near.isEmpty {
            Log.info("bluetooth sees \(order.filter(isNear).count) of \(hotspots.count) hotspots nearby")
        }
        // Only the first problem of the pass becomes the report, so the
        // menu names the first hotspot tried that has one. Every problem
        // is still logged and notified.
        var reported = false
        for ssid in order {
            let place = Self.place(of: ssid, in: hotspots)
            let suffix = place.map { ", \($0)" } ?? ""
            // Settings may have taken it off the list while an earlier
            // hotspot was read or joined.
            guard configProvider().hotspotsToJoin.contains(ssid) else { continue }
            if isNear(ssid) {
                switch await joinWoken(ssid, interfaceName: iface, place: suffix) {
                case .joined: return
                case .gone: return
                case .notWoken: break
                case .notJoined: continue
                }
            }
            // Handed over by a wake earlier this session.
            if let earlier = handedOver[HotspotSSID.folded(ssid)] {
                Log.info("joining hotspot \(earlier.ssid) on \(iface) with the password it handed over earlier (attempt \(machine.joins)\(suffix))")
                if await failoverJoin(earlier, interfaceName: iface, label: "hotspot \(earlier.ssid)") { return }
                guard !Task.isCancelled, self.epoch == epoch, self.outage == outage else { return }
                continue
            }
            // Off the main actor, behind any save Settings has running,
            // which may be waiting on a keychain dialog. Everything the
            // join depends on is checked again after the wait: the
            // session, the outage and the configured hotspots.
            let read = await readPassword(for: ssid)
            guard !Task.isCancelled, self.epoch == epoch else {
                Log.info("hotspot join dropped: the session ended during the keychain read")
                return
            }
            guard self.outage == outage else {
                Log.info("hotspot join dropped: Wi-Fi recovered during the keychain read")
                return
            }
            // Settings may have changed the hotspots meanwhile. The answer,
            // a password or a problem, is about one no longer configured;
            // the retry timer stays, and the next tick reads the hotspots
            // configured then.
            let configured = configProvider().hotspotsToJoin
            guard configured.contains(ssid) else {
                Log.info("hotspot join dropped: the hotspot SSID changed during the keychain read\(suffix)")
                continue
            }
            let password: String
            switch read {
            case let .success(p?):
                password = p
                // A readable password ends the report about this hotspot,
                // and one about a hotspot no longer configured.
                if let current = passwordReport, current.ssid == ssid || !configured.contains(current.ssid) {
                    passwordReport = nil
                }
            case .success(nil) where configProvider().hotspotPriorityEnabled:
                // The list needs no saved password: a device it could not
                // wake is skipped for now, with no report.
                Log.info("hotspot join skipped (\(place ?? "the hotspot")): not woken over Bluetooth, and no password saved")
                continue
            case .success(nil):
                report(.missing, for: ssid, place: place, publish: !reported)
                reported = true
                continue
            case let .failure(error):
                report(HotspotPasswordProblem(error), for: ssid, place: place, publish: !reported)
                reported = true
                continue
            }
            Log.info("joining hotspot \(ssid) on \(iface) (attempt \(machine.joins)\(suffix))")
            if await failoverJoin(HotspotCredentials(ssid: ssid, password: password), interfaceName: iface, label: "hotspot \(ssid)") { return }
            // The scan and the join take seconds: the session may have
            // ended or Wi-Fi come back meanwhile, and then the next
            // hotspot must not be joined.
            guard !Task.isCancelled, self.epoch == epoch, self.outage == outage else { return }
        }
    }

    private enum WokenJoin { case joined, notJoined, notWoken, gone }

    /// Wakes the device named `ssid` and joins the network it hands over,
    /// looking for it a few times while it comes on the air. `notWoken`
    /// leaves the saved password to try; `gone` means the session ended or
    /// Wi-Fi came back meanwhile.
    private func joinWoken(_ ssid: String, interfaceName iface: String, place: String) async -> WokenJoin {
        let epoch = self.epoch
        let outage = self.outage
        let valid = { !Task.isCancelled && self.epoch == epoch && self.outage == outage }
        Log.info("waking hotspot \(ssid) over Bluetooth\(place)")
        let started = clock()
        let woken = await waker.wake(ssid)
        guard valid() else { return .gone }
        guard let woken else {
            Log.info("hotspot \(ssid) did not wake; trying its saved password")
            return .notWoken
        }
        handedOver[HotspotSSID.folded(ssid)] = woken
        Log.info("hotspot \(woken.ssid) woke after \(String(format: "%.1f", clock().timeIntervalSince(started))) s")
        for look in 1...wokenJoinTries {
            Log.info("joining woken hotspot \(woken.ssid) on \(iface) (look \(look) of \(wokenJoinTries)\(place))")
            if await failoverJoin(woken, interfaceName: iface, label: "woken hotspot \(woken.ssid)") { return .joined }
            guard valid() else { return .gone }
            if look < wokenJoinTries {
                try? await Task.sleep(for: wokenJoinWait)
                guard valid() else { return .gone }
            }
        }
        return .notJoined
    }

    private enum JoinOutcome { case joined, notFound, failed(any Error) }

    /// Joins `credentials`; once joined, it is the hotspot Insomnia joined.
    private func join(_ credentials: HotspotCredentials, interfaceName iface: String) async -> JoinOutcome {
        do {
            guard try await hotspotJoiner.join(ssid: credentials.ssid, password: credentials.password, interfaceName: iface) else { return .notFound }
            joinedHotspot = credentials.ssid
            return .joined
        } catch {
            return .failed(error)
        }
    }

    /// A failover join of `credentials`, its failure logged about `label`.
    private func failoverJoin(_ credentials: HotspotCredentials, interfaceName iface: String, label: String) async -> Bool {
        switch await join(credentials, interfaceName: iface) {
        case .joined:
            return true
        case .notFound:
            Log.error("CoreWLAN scan found no network for \(label)")
        case let .failed(error):
            Log.error("CoreWLAN join of \(label) failed: \(error.localizedDescription)")
        }
        return false
    }

    /// "hotspot 2 of 3" for the log, matched whichever apostrophe; nil
    /// with one hotspot configured, or for one not on the list.
    static func place(of ssid: String, in hotspots: [String]) -> String? {
        guard hotspots.count > 1, let index = hotspots.firstIndex(where: { HotspotSSID.matches($0, ssid) }) else { return nil }
        return "hotspot \(index + 1) of \(hotspots.count)"
    }

    /// The network name and password to join the hotspot `ssid` with:
    /// what the device hands over when woken (only when `waking`), else
    /// what it handed over earlier this session, else its saved password.
    private func credentials(for ssid: String, waking: Bool) async -> HotspotCredentials? {
        if waking, let woken = await waker.wake(ssid) {
            handedOver[HotspotSSID.folded(ssid)] = woken
            return woken
        }
        if let earlier = handedOver[HotspotSSID.folded(ssid)] { return earlier }
        if case let .success(password?) = await readPassword(for: ssid) {
            return HotspotCredentials(ssid: ssid, password: password)
        }
        return nil
    }

    private func readPassword(for ssid: String) async -> Result<String?, any Error> {
        let keychain = self.keychain
        do {
            return .success(try await keychainQueue.run { try keychain.get(service: KeychainStore.service, account: ssid) })
        } catch {
            return .failure(error)
        }
    }

    /// The join is skipped: log it, show it in the menu when `publish`,
    /// and notify once per outage and hotspot. The log line names the
    /// problem and the hotspot's place on the list, not the SSID. With
    /// several hotspots configured (a `place`) the notification names the
    /// one it is about.
    private func report(_ problem: HotspotPasswordProblem, for ssid: String, place: String?, publish: Bool) {
        Log.error("hotspot join skipped\(place.map { " (\($0))" } ?? ""): \(problem.explanation)")
        if publish {
            passwordReport = HotspotPasswordReport(ssid: ssid, problem: problem)
        }
        guard notifiedThisOutage.insert(ssid).inserted else { return }
        notifier.post(title: place != nil ? "Hotspot \"\(ssid)\" not joined" : "Hotspot not joined", body: problem.explanation)
    }

    private func recovered(start: Date, gap: TimeInterval) async {
        let epoch = self.epoch
        let end = clock()
        lastGap = gap
        let line = FailoverMachine.logLine(start: start, end: end, gap: gap)
        appendHandoff(line)
        Log.info("wifi path satisfied after \(FailoverMachine.humanGap(gap))")
        if let iface = wifiInterface {
            landed(on: await scanner.currentSSID(interfaceName: iface).map(HotspotSSID.normalized))
        }
        let config = configProvider()
        if gap >= config.nudgeThreshold {
            // Each pane is only nudged while this session is still the live one.
            let count = await nudge.nudge(targets: config.tmuxTargets, pressEnter: config.tmuxNudgePressesEnter) { [weak self] in self?.epoch == epoch }
            let stopped = self.epoch != epoch
            if stopped {
                Log.info("network failover stopped during recovery; \(count) tmux pane(s) had already been nudged")
            }
            // A keystroke that went out before the stop is still reported.
            if !stopped || count > 0 {
                let panes = count == 1 ? "1 tmux pane" : "\(count) tmux panes"
                notifier.post(
                    title: "Network recovered",
                    body: "Network was down \(FailoverMachine.humanGap(gap)). Nudged \(panes). Check GUI agents."
                )
            }
        }
        // A stopped driver must not write into the next session's status.
        guard self.epoch == epoch else { return }
        onRecovered?(gap)
    }

    /// Logs the network an outage ended on, by its tag, and what that
    /// means for the hotspot Insomnia joined: on any network but a listed
    /// hotspot, the Mac has left it.
    private func landed(on now: String?) {
        let hotspots = configProvider().hotspotsToJoin
        let listed = now.map { HotspotSSID.any(of: hotspots, matches: $0) } ?? false
        if let h = handingBack {
            handingBack = nil
            if let now, !listed {
                Log.info("handed back: macOS rejoined saved Wi-Fi \(tag(now))")
            } else {
                Log.info("hand-back to \(tag(h.network)): macOS joined \(now.map { tag($0) } ?? "a network it does not name") instead; no more hand-backs to it this session")
                refusedHandBacks.append(h.network)
                // Back on a listed hotspot because of the hand-back: it is
                // still Insomnia's, so the next try comes after the cooldown.
                if let now { joinedHotspot = now }
            }
            return
        }
        guard let now else {
            Log.info("back online; macOS does not name the network")
            return
        }
        Log.info("back online on \(tag(now))\(Self.place(of: now, in: hotspots).map { ", \($0)" } ?? "")")
        observe(now)
    }

    /// The Mac is on `current`: on a network that is not a listed
    /// hotspot, it has left the one Insomnia joined.
    private func observe(_ current: String?) {
        guard let current, let joined = joinedHotspot, !HotspotSSID.matches(current, joined),
              !HotspotSSID.any(of: configProvider().hotspotsToJoin, matches: current) else { return }
        joinedHotspot = nil
    }

    private struct JoinedHotspotRecord: Codable {
        let ssid: String
    }

    private static func loadJoinedHotspot(_ paths: Paths) -> String? {
        do {
            return try Store(paths: paths).read(JoinedHotspotRecord.self, from: paths.joinedHotspotFile)?.ssid
        } catch {
            Log.error("joined-hotspot.json: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveJoinedHotspot() {
        let store = Store(paths: paths)
        do {
            if let joinedHotspot {
                try store.write(JoinedHotspotRecord(ssid: joinedHotspot), to: paths.joinedHotspotFile)
            } else {
                try store.remove(at: paths.joinedHotspotFile)
            }
        } catch {
            Log.error("joined-hotspot.json: \(error.localizedDescription)")
        }
    }

    /// Owner-only, rotated to handoffs.log.1 past OwnerOnly.maxLogBytes.
    private func appendHandoff(_ line: String) {
        do {
            try OwnerOnly.appendToLog(line + "\n", at: paths.handoffsLog)
        } catch {
            Log.error("handoffs.log: \(error.localizedDescription)")
        }
    }
}
