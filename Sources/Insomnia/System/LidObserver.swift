import AppKit
import IOKit
import IOKit.graphics

/// The lid as the registry and the display list report it. `closedAtDesk`
/// is a closed lid with an external display connected: closed-display
/// mode, the Mac in use at a desk.
enum LidReading: Equatable, Sendable {
    case open
    case closedAtDesk
    case closed
}

/// Spec section 3: IOKit interest notification on `IOPMrootDomain`, and
/// AppKit's screen-parameters notification for displays that come and go.
/// Between events nothing runs. A change is delivered only if the state is
/// still the same 2 s later.
///
/// A lid closed at a desk keeps the state delivered before it: closed with
/// an external display connected, it stays open, and the countdown and the
/// apps keep running; closed in a bag, it stays closed when a display is
/// plugged in, until the lid opens and the built-in panel can be lit
/// again. Unplugging the last external display of a lid closed at a desk
/// delivers the close (`closedByDisplayLoss`), and plugging one in again
/// the open.
@MainActor
final class LidObserver {
    nonisolated static let debounce: TimeInterval = 2
    nonisolated static let clamshellKey = "AppleClamshellState"

    /// Called on the main actor after the debounce, with `true` for closed.
    var onChange: ((Bool) -> Void)?
    /// Whether the journal holds a saved display or keyboard brightness.
    /// Only a lid open may restore one, so while it does, a display plugged
    /// in again leaves a lid closed by its unplugging closed.
    var brightnessJournaled: () -> Bool = { false }

    /// Last delivered state, refreshed from the registry when read.
    var isClosed: Bool {
        read().map(counts) ?? lastDelivered
    }

    /// The lid is down, whether it counts as closed or not: the built-in
    /// panel and keyboard are under it.
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
    private var lastReading: LidReading?
    private var pending: Bool?
    private var debounceTimer: Timer?
    private var settledWaiter: ((Bool) -> Void)?

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

    /// Registry and display list; nil when the lid is unavailable.
    nonisolated static func readLid() -> LidReading? {
        let closed = readClamshellState()
        return reading(closed: closed, externalDisplay: closed == true && externalDisplayConnected())
    }

    /// Pure registry read: true = closed, false = open, nil = unavailable
    /// (no IOPMrootDomain or no clamshell, e.g. a desktop). A lid closed at
    /// a desk reads closed here.
    nonisolated static func readClamshellState() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, clamshellKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue)
    }

    nonisolated static func reading(closed: Bool?, externalDisplay: Bool) -> LidReading? {
        guard let closed else { return nil }
        guard closed else { return .open }
        return externalDisplay ? .closedAtDesk : .closed
    }

    /// A display other than the built-in panel is online, asleep or not.
    /// With the lid closed and nothing plugged in, macOS keeps a stand-in
    /// display online, of vendor `kDisplayVendorIDUnknown` (`unkn`): it is
    /// not one.
    nonisolated static func externalDisplayConnected() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { isExternal(builtIn: CGDisplayIsBuiltin($0) != 0, vendor: CGDisplayVendorNumber($0)) }
    }

    nonisolated static func isExternal(builtIn: Bool, vendor: UInt32) -> Bool {
        !builtIn && vendor != UInt32(kDisplayVendorIDUnknown)
    }

    /// Whether `reading` counts as closed: a lid closed at a desk keeps the
    /// state delivered last, unless the display going away closed it.
    private func counts(_ reading: LidReading) -> Bool {
        switch reading {
        case .open: false
        case .closed: true
        case .closedAtDesk: lastDelivered && (!closedByDisplayLoss || brightnessJournaled())
        }
    }

    /// Takes the lid from the registry, and a lid closed at a desk as
    /// `closed`: whether the session took the lid as closed when it became
    /// active.
    func seed(closed: Bool) {
        closedByDisplayLoss = false
        lastReading = read()
        switch lastReading {
        case .open?, nil: lastDelivered = false
        case .closed?: lastDelivered = true
        case .closedAtDesk?: lastDelivered = closed
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
        screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
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
        guard let reading = read() else { return }
        let displayLoss = reading == .closed && lastReading == .closedAtDesk
        if reading == .closedAtDesk, lastReading != .closedAtDesk {
            Log.info("lid \(Self.atDesk(counted: counts(.closedAtDesk)))")
        } else if displayLoss {
            Log.info("lid closed, and its last external display is gone")
        }
        lastReading = reading
        let now = counts(reading)
        guard now != lastDelivered else {
            // Flapped back to the delivered state; drop the pending change.
            if pending != nil {
                pending = nil
                debounceTimer?.invalidate()
                debounceTimer = nil
                settled(delivered: false)
            }
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
        pending = nil
        guard let reading = read(), case let now = counts(reading), now == candidate, now != lastDelivered else {
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

    private static func atDesk(counted closed: Bool) -> String {
        "closed with an external display connected: \(closed ? "still counted as closed until it opens" : "counted as open")"
    }

    private func settled(delivered: Bool) {
        let waiter = settledWaiter
        settledWaiter = nil
        waiter?(delivered)
    }
}
