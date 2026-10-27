import AppKit
import IOKit
import IOKit.graphics

/// The lid as the registry and the display list report it. `closedAtDesk`
/// is a closed lid with an external display connected: closed-display
/// mode, the Mac in use at a desk. `closedDisplaysUnknown` is a closed lid
/// whose display list could not be read, at a desk or not.
enum LidReading: Equatable, Sendable {
    case open
    case closedAtDesk
    case closed
    case closedDisplaysUnknown
}

/// Spec section 3: IOKit interest notification on `IOPMrootDomain`, and
/// AppKit's screen-parameters notification for displays that come and go.
/// Between events nothing runs, except while the lid reads closed and the
/// display list cannot be read: the lid is read again every 2 s then, until
/// the list reads or the lid opens. A change is delivered only if the state
/// is still the same 2 s later.
///
/// A lid closed at a desk keeps the state delivered before it: closed with
/// an external display connected, it stays open, and the countdown and the
/// apps keep running; closed in a bag, it stays closed when a display is
/// plugged in, until the lid opens and the built-in panel can be lit
/// again. Unplugging the last external display of a lid closed at a desk
/// delivers the close (`closedByDisplayLoss`), and plugging one in again
/// the open. A closed lid whose display list cannot be read keeps the
/// state delivered before it too, and drops a change waiting out the
/// debounce, since it may be at a desk or in a bag.
@MainActor
final class LidObserver {
    nonisolated static let debounce: TimeInterval = 2
    /// Posted when a display comes, goes or changes.
    nonisolated static let displaysChanged = NSApplication.didChangeScreenParametersNotification
    nonisolated static let clamshellKey = "AppleClamshellState"

    /// Called on the main actor after the debounce, with `true` for closed.
    var onChange: ((Bool) -> Void)?
    /// Whether the journal holds a saved display or keyboard brightness.
    /// Only a lid open may restore one, so while it does, a display plugged
    /// in again leaves a lid closed by its unplugging closed.
    var brightnessJournaled: () -> Bool = { false }

    /// Last delivered state, refreshed from the registry when read. A
    /// closed lid whose display list cannot be read keeps it.
    var isClosed: Bool {
        read().map(counts) ?? lastDelivered
    }

    /// The lid is down, whether it counts as closed or not, and whether its
    /// display list reads or not: the built-in panel and keyboard are under
    /// it.
    var isShut: Bool {
        (read() ?? .open) != .open
    }

    private let read: () -> LidReading?
    private let debounce: TimeInterval
    private var lastDelivered: Bool = false
    /// The close delivered last came from the last external display going
    /// away under a lid already shut: a display plugged in again opens it,
    /// unless a saved brightness waits for the lid to open.
    private(set) var closedByDisplayLoss = false
    private var pendingByDisplayLoss = false
    /// The last reading other than `closedDisplaysUnknown`: a display list
    /// that cannot be read tells nothing new about the lid.
    private var lastReading: LidReading?
    /// The lid has read closed at a desk since it last read open, at an
    /// event or when the debounce ended, so a close now comes from its last
    /// external display going away. Kept through unreadable display lists.
    private var atDeskSinceOpen = false
    private var pending: Bool?
    private var debounceTimer: Timer?
    private var settledWaiter: ((Bool) -> Void)?
    /// The lid reads closed and its display list cannot be read: logged
    /// once when that starts and once when it ends.
    private var displaysUnknown = false
    /// The next read of a lid whose display list could not be read
    /// (`readDisplaysAgainLater`), the one timer that runs between events.
    private var displaysTimer: Timer?
    /// Counts the reads armed, so one that fired before `stop` or a newer
    /// one does nothing.
    private var displaysTicket = 0

    private var port: IONotificationPortRef?
    private var service: io_service_t = 0
    private var notification: io_object_t = 0
    private var screensObserver: NSObjectProtocol?

    /// `read` and `debounce` are injectable for tests; the app uses the
    /// registry and the 2 s debounce.
    init(read: @escaping () -> LidReading? = LidObserver.readLid, debounce: TimeInterval = LidObserver.debounce) {
        self.read = read
        self.debounce = debounce
    }

    /// Registry and display list; nil when the lid is unavailable. The
    /// display list is read for a closed lid only.
    nonisolated static func readLid() -> LidReading? {
        let closed = readClamshellState()
        return reading(closed: closed, externalDisplay: closed == true ? readExternalDisplay() : nil)
    }

    /// Pure registry read: true = closed, false = open, nil = unavailable
    /// (no IOPMrootDomain or no clamshell, e.g. a desktop). A lid closed at
    /// a desk reads closed here.
    nonisolated static func readClamshellState() -> Bool? {
        readRootDomainBool(clamshellKey)
    }

    /// A boolean property of IOPMrootDomain; nil when the service or the
    /// property is missing.
    nonisolated static func readRootDomainBool(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue)
    }

    /// `externalDisplay` nil is a display list that could not be read.
    nonisolated static func reading(closed: Bool?, externalDisplay: Bool?) -> LidReading? {
        guard let closed else { return nil }
        guard closed else { return .open }
        switch externalDisplay {
        case true?: return .closedAtDesk
        case false?: return .closed
        case nil: return .closedDisplaysUnknown
        }
    }

    /// A display other than the built-in panel is online, asleep or not;
    /// nil when the display list cannot be read. With the lid closed and
    /// nothing plugged in, macOS keeps a stand-in display online, of vendor
    /// `kDisplayVendorIDUnknown` (`unkn`): it is not one.
    nonisolated static func readExternalDisplay() -> Bool? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).contains { isExternal(builtIn: CGDisplayIsBuiltin($0) != 0, vendor: CGDisplayVendorNumber($0)) }
    }

    nonisolated static func isExternal(builtIn: Bool, vendor: UInt32) -> Bool {
        !builtIn && vendor != UInt32(kDisplayVendorIDUnknown)
    }

    /// Whether `reading` counts as closed: a lid closed at a desk keeps the
    /// state delivered last, unless the display going away closed it, and
    /// so does a closed lid whose display list cannot be read.
    private func counts(_ reading: LidReading) -> Bool {
        switch reading {
        case .open: false
        case .closed: true
        case .closedAtDesk: lastDelivered && (!closedByDisplayLoss || brightnessJournaled())
        case .closedDisplaysUnknown: lastDelivered
        }
    }

    /// Takes the lid from the registry, and a lid closed at a desk as
    /// `closed`: whether the session took the lid as closed when it became
    /// active. It takes a closed lid whose display list cannot be read the
    /// same way, and reads it again until the list reads.
    func seed(closed: Bool) {
        closedByDisplayLoss = false
        let reading = read()
        switch reading {
        case .open?, nil: lastDelivered = false
        case .closed?: lastDelivered = true
        case .closedAtDesk?, .closedDisplaysUnknown?: lastDelivered = closed
        }
        // A session takes a closed lid as open only at a desk.
        atDeskSinceOpen = reading == .closedAtDesk || (reading == .closedDisplaysUnknown && !closed)
        if reading == .closedDisplaysUnknown {
            lastReading = nil
            readDisplaysAgainLater()
        } else {
            lastReading = reading
            endDisplaysUnknown(reading)
        }
    }

    /// `closed` is for `seed`.
    func start(closed: Bool = false) {
        guard port == nil else { return }
        seed(closed: closed)
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {
            Log.error("lid observer: IOPMrootDomain not found")
            return
        }
        guard let p = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.error("lid observer: IONotificationPortCreate failed")
            IOObjectRelease(service)
            service = 0
            return
        }
        port = p
        let source = IONotificationPortGetRunLoopSource(p).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let kr = IOServiceAddInterestNotification(p, service, kIOGeneralInterest, Self.callback, refcon, &notification)
        guard kr == KERN_SUCCESS else {
            Log.error("lid observer: IOServiceAddInterestNotification failed (\(kr))")
            stop()
            return
        }
        screensObserver = NotificationCenter.default.addObserver(forName: Self.displaysChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleInterest() }
        }
        let lid = lastReading == .closedAtDesk ? Self.atDesk(counted: lastDelivered) : lastDelivered ? "closed" : "open"
        Log.info("lid observer started (lid \(lid))")
    }

    func stop() {
        if let screensObserver {
            NotificationCenter.default.removeObserver(screensObserver)
            self.screensObserver = nil
        }
        debounceTimer?.invalidate()
        debounceTimer = nil
        pending = nil
        settledWaiter = nil
        displaysTimer?.invalidate()
        displaysTimer = nil
        displaysUnknown = false
        if notification != 0 {
            IOObjectRelease(notification)
            notification = 0
        }
        if let p = port {
            let source = IONotificationPortGetRunLoopSource(p).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            IONotificationPortDestroy(p)
            port = nil
        }
        if service != 0 {
            IOObjectRelease(service)
            service = 0
        }
    }

    /// Runs `body` once no lid change is waiting out the debounce: at once
    /// if none is, otherwise when the change is delivered (`true`, after
    /// `onChange` has run) or dropped as a flap (`false`). A caller that
    /// acts on the lid state waits here so it never acts on the state a
    /// pending change is about to replace. One waiter at a time: a newer
    /// one replaces it. `stop` drops it.
    func whenSettled(_ body: @escaping (_ delivered: Bool) -> Void) {
        guard pending != nil else {
            body(false)
            return
        }
        settledWaiter = body
    }

    /// Any message from IOPMrootDomain, or a change of screens: re-read and
    /// debounce. Internal so a test can deliver one.
    func handleInterest() {
        guard let reading = read() else {
            // A lid that cannot be read tells nothing new about one whose
            // display list could not be read: keep reading it.
            if displaysUnknown { readDisplaysAgainLater() }
            return
        }
        guard reading != .closedDisplaysUnknown else {
            readDisplaysAgainLater()
            return
        }
        endDisplaysUnknown(reading)
        let displayLoss = record(reading)
        let now = counts(reading)
        guard now != lastDelivered else {
            // Flapped back to the delivered state; drop the pending change.
            dropPending()
            return
        }
        guard pending != now else { return }
        pending = now
        pendingByDisplayLoss = displayLoss
        debounceTimer?.invalidate()
        let timer = Timer(timeInterval: debounce, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.settle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        debounceTimer = timer
    }

    // MARK: Private

    private static let callback: IOServiceInterestCallback = { refcon, _, _, _ in
        guard let refcon else { return }
        let observer = Unmanaged<LidObserver>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { observer.handleInterest() }
    }

    private func settle() {
        debounceTimer = nil
        guard let candidate = pending else { return }
        let reading = read()
        guard reading != .closedDisplaysUnknown else {
            readDisplaysAgainLater()
            return
        }
        pending = nil
        if let reading { record(reading) }
        guard let reading, case let now = counts(reading), now == candidate, now != lastDelivered else {
            Log.info("lid observer: change flapped within \(Int(debounce)) s, ignored")
            settled(delivered: false)
            return
        }
        lastDelivered = now
        closedByDisplayLoss = now && pendingByDisplayLoss
        Log.info("lid \(now ? "closed" : "open")")
        onChange?(now)
        settled(delivered: true)
    }

    /// Takes a reading other than `closedDisplaysUnknown` into the lid's
    /// history, at an event or when the debounce ends, whether the reading
    /// keeps a waiting change or drops it. Returns whether a close now
    /// comes from the lid's last external display going away.
    @discardableResult
    private func record(_ reading: LidReading) -> Bool {
        let displayLoss = reading == .closed && atDeskSinceOpen
        if reading == .closedAtDesk, lastReading != .closedAtDesk {
            Log.info("lid \(Self.atDesk(counted: counts(.closedAtDesk)))")
        } else if displayLoss, lastReading != .closed {
            Log.info("lid closed, and its last external display is gone")
        }
        switch reading {
        case .open: atDeskSinceOpen = false
        case .closedAtDesk: atDeskSinceOpen = true
        case .closed, .closedDisplaysUnknown: break
        }
        lastReading = reading
        return displayLoss
    }

    /// The lid reads closed and its display list cannot be read, so it may
    /// be at a desk or in a bag: the observer keeps the state delivered
    /// last, drops a change waiting out the debounce, and reads the lid
    /// again after the debounce with no event needed. It keeps a read
    /// already armed, so events that keep coming do not put it off.
    private func readDisplaysAgainLater() {
        if !displaysUnknown {
            displaysUnknown = true
            Log.info("lid closed, display list unreadable; reading it again in \(Int(debounce)) s")
        }
        dropPending()
        guard displaysTimer == nil else { return }
        displaysTicket += 1
        let ticket = displaysTicket
        let timer = Timer(timeInterval: debounce, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.displaysTimerFired(ticket) }
        }
        RunLoop.main.add(timer, forMode: .common)
        displaysTimer = timer
    }

    private func displaysTimerFired(_ ticket: Int) {
        guard ticket == displaysTicket, displaysTimer != nil else { return }
        displaysTimer = nil
        handleInterest()
    }

    /// A reading other than `closedDisplaysUnknown` came in: the read armed
    /// for the display list stops, and the usual rules take the reading.
    private func endDisplaysUnknown(_ reading: LidReading?) {
        guard displaysUnknown else { return }
        displaysUnknown = false
        displaysTimer?.invalidate()
        displaysTimer = nil
        Log.info(reading == .open ? "lid opened before its display list could be read" : "lid display list readable again")
    }

    /// Drops a change waiting out the debounce and tells the waiter.
    private func dropPending() {
        guard pending != nil else { return }
        pending = nil
        debounceTimer?.invalidate()
        debounceTimer = nil
        settled(delivered: false)
    }

    private static func atDesk(counted closed: Bool) -> String {
        "closed with an external display connected: \(closed ? "still counted as closed until it opens" : "counted as open")"
    }

    private func settled(delivered: Bool) {
        let waiter = settledWaiter
        settledWaiter = nil
        waiter?(delivered)
    }
}

/// Lid changes that held through the debounce, delivered on the main
/// actor. `SessionManager` watches the lid with one while a closed lid's
/// sleep is owed, apart from the session's own observer, which stops with
/// the end.
@MainActor
protocol LidWatching: AnyObject {
    /// Called with `true` for closed.
    var onChange: ((Bool) -> Void)? { get set }
    /// `closed`: whether a lid closed at a desk counts as closed to start
    /// with (`LidObserver.seed`).
    func start(closed: Bool)
    func stop()
}

extension LidObserver: LidWatching {}

/// Delivers nothing, for a manager built without a lid.
@MainActor
final class NoopLidWatcher: LidWatching {
    var onChange: ((Bool) -> Void)?
    func start(closed: Bool) {}
    func stop() {}
}
