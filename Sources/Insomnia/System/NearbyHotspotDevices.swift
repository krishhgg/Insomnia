import Foundation

/// A phone or tablet that offers Instant Hotspot nearby, as macOS finds it
/// over Bluetooth. Its hotspot need not be on: macOS sees the device, not
/// the network. The device name is the name its hotspot uses as its SSID.
struct NearbyHotspotDevice: Equatable, Sendable {
    let name: String
    /// Battery percentage, or nil when not reported.
    let battery: Int?
}

protocol NearbyHotspotBrowsing: Sendable {
    /// Browses for `seconds`, or until the task is cancelled, and hands
    /// `update` the whole list each time macOS changes it. Never calls
    /// `update` when this macOS does not offer the calls below as measured.
    @MainActor
    func browse(for seconds: TimeInterval, update: @escaping @MainActor ([NearbyHotspotDevice]) -> Void) async
}

/// Read-only discovery through `SFRemoteHotspotSession` in the private
/// Sharing.framework, the class behind the Personal Hotspot list in the
/// Wi-Fi menu. Measured on macOS 27: an ad-hoc signed process may browse,
/// and sharingd answers at once with its cached list through the delegate
/// method `session:updatedFoundDevices:`, whose devices answer
/// `deviceName`, `signalStrength` and `batteryLife` (the name and battery
/// are read). The browser only
/// browses: turning a hotspot on is `SharingHotspotWaker`'s. Every class
/// and selector is checked before it is called, so a macOS that changed
/// them returns no devices instead of raising an exception.
struct SharingHotspotBrowser: NearbyHotspotBrowsing {
    static let framework = "/System/Library/PrivateFrameworks/Sharing.framework/Sharing"

    @MainActor
    func browse(for seconds: TimeInterval, update: @escaping @MainActor ([NearbyHotspotDevice]) -> Void) async {
        guard let session = Self.makeSession() else {
            Log.info("nearby hotspot devices unavailable: SFRemoteHotspotSession is not as measured")
            return
        }
        let collector = NearbyHotspotCollector(update: update)
        _ = session.perform(NSSelectorFromString("setDelegate:"), with: collector)
        _ = session.perform(NSSelectorFromString("startBrowsing"))
        // A cancelled task ends the sleep, and so the browse, early.
        try? await Task.sleep(for: .seconds(seconds))
        _ = session.perform(NSSelectorFromString("stopBrowsing"))
        _ = session.perform(NSSelectorFromString("setDelegate:"), with: nil)
        // The delegate may be weak: keep the collector alive until the stop.
        withExtendedLifetime(collector) {}
    }

    static func makeSession() -> NSObject? {
        guard dlopen(framework, RTLD_LAZY) != nil,
              let type = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else { return nil }
        let needed = ["setDelegate:", "startBrowsing", "stopBrowsing"]
        guard needed.allSatisfy({ type.instancesRespond(to: NSSelectorFromString($0)) }) else { return nil }
        return type.init()
    }
}

/// The delegate sharingd calls, on its connection's queue, with the whole
/// list each time it changes. Each list goes to the main queue in the
/// order it came, so a newer list is never overwritten by an older one.
private final class NearbyHotspotCollector: NSObject, Sendable {
    private let update: @MainActor ([NearbyHotspotDevice]) -> Void

    init(update: @escaping @MainActor ([NearbyHotspotDevice]) -> Void) {
        self.update = update
    }

    @objc(session:updatedFoundDevices:)
    func session(_ session: AnyObject, updatedFoundDevices list: NSArray) {
        let parsed = list.compactMap { Self.device(from: $0 as AnyObject) }
        let update = self.update
        DispatchQueue.main.async {
            MainActor.assumeIsolated { update(parsed) }
        }
    }

    private static func device(from object: AnyObject) -> NearbyHotspotDevice? {
        guard let object = object as? NSObject,
              let name = value("deviceName", of: object) as? String, !name.isEmpty else { return nil }
        return NearbyHotspotDevice(
            name: name,
            battery: (value("batteryLife", of: object) as? NSNumber)?.intValue
        )
    }

    /// Key-value coding raises an exception Swift cannot catch for a key
    /// the object lacks, so the getter is checked first.
    private static func value(_ key: String, of object: NSObject) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }
}

/// Test double: hands over its list at once, as sharingd does with its
/// cached one, then holds the browse open like the real one.
struct FixedNearbyHotspotDevices: NearbyHotspotBrowsing {
    var list: [NearbyHotspotDevice] = []

    @MainActor
    func browse(for seconds: TimeInterval, update: @escaping @MainActor ([NearbyHotspotDevice]) -> Void) async {
        update(list)
        try? await Task.sleep(for: .seconds(seconds))
    }
}

// MARK: - Waking a hotspot

/// What a woken hotspot hands over: the network to join and its password.
struct HotspotCredentials: Equatable, Sendable {
    let ssid: String
    let password: String
}

/// An iPhone or iPad keeps its hotspot off the air while nothing uses it,
/// even with "Allow Others to Join" on, so a Wi-Fi scan cannot find it. A
/// Mac signed in to the same Apple Account asks it over Bluetooth to turn
/// the hotspot on, as the Wi-Fi menu does when you pick the device.
protocol HotspotWaking: Sendable {
    /// The names of the phones and tablets macOS sees over Bluetooth now.
    @MainActor
    func nearbyNames() async -> [String]
    /// Asks the device named `name`, either apostrophe, to turn its
    /// hotspot on. The network and password it hands over, or nil when no
    /// device by that name is near or it did not answer.
    @MainActor
    func wake(_ name: String) async -> HotspotCredentials?
}

/// Wakes nothing: the default, so that only the app, which passes
/// `SharingHotspotWaker`, ever turns a real device's hotspot on.
struct NoHotspotWaker: HotspotWaking {
    @MainActor
    func nearbyNames() async -> [String] { [] }
    @MainActor
    func wake(_ name: String) async -> HotspotCredentials? { nil }
}

/// Wakes a hotspot through `SFRemoteHotspotSession`'s
/// `enableHotspotForDevice:withCompletionHandler:`. Measured on macOS 27
/// from an ad-hoc signed process with the lid closed: the completion came
/// 2.7 s after the call with the hotspot's network name and its password,
/// both strings, and a scan found the network at once after. The password
/// is used for the join and never logged.
struct SharingHotspotWaker: HotspotWaking {
    static let enable = "enableHotspotForDevice:withCompletionHandler:"
    /// How long the device list may take to come; sharingd answers with
    /// its cached one at once.
    var listWait: TimeInterval = 2
    /// How long a device may take to answer the wake.
    var answerWait: TimeInterval = 20

    @MainActor
    func nearbyNames() async -> [String] {
        guard let browse = HotspotDeviceBrowse.start() else { return [] }
        defer { browse.stop() }
        return await browse.devices(within: listWait).compactMap(HotspotDeviceBrowse.name)
    }

    @MainActor
    func wake(_ name: String) async -> HotspotCredentials? {
        guard let browse = HotspotDeviceBrowse.start() else { return nil }
        // Browsing stops only once the device has answered.
        defer { browse.stop() }
        let devices = await browse.devices(within: listWait)
        guard let device = devices.first(where: { HotspotDeviceBrowse.name(of: $0).map { HotspotSSID.matches($0, name) } ?? false }) else {
            Log.info("hotspot wake skipped: no device named \(name) is near over Bluetooth")
            return nil
        }
        guard browse.session.responds(to: NSSelectorFromString(Self.enable)) else {
            Log.info("hotspot wake unavailable: SFRemoteHotspotSession is not as measured")
            return nil
        }
        let answerWait = self.answerWait
        return await withCheckedContinuation { (continuation: CheckedContinuation<HotspotCredentials?, Never>) in
            let once = ResumeOnce(continuation)
            Self.enable(on: browse.session, device: device) { first, second in
                once.resume(Self.credentials(first, second))
            }
            Task {
                try? await Task.sleep(for: .seconds(answerWait))
                if once.resume(nil) { Log.error("hotspot wake: \(name) did not answer within \(Int(answerWait)) s") }
            }
        }
    }

    /// Sends the enable message. Sharing keeps the completion and calls it
    /// seconds later, so the block must be escaping: a non-escaping one
    /// traps the app the moment Sharing retains it.
    static func enable(on session: NSObject, device: NSObject, completion: @escaping (AnyObject?, AnyObject?) -> Void) {
        typealias Completion = @convention(block) (AnyObject?, AnyObject?) -> Void
        typealias Enable = @convention(c) (NSObject, Selector, NSObject, @escaping Completion) -> Void
        let selector = NSSelectorFromString(enable)
        let call = unsafeBitCast(session.method(for: selector), to: Enable.self)
        call(session, selector, device, completion)
    }

    /// The completion's two values: the network name and the password on
    /// success. Anything else is a failure; an error is logged.
    private static func credentials(_ first: AnyObject?, _ second: AnyObject?) -> HotspotCredentials? {
        if let ssid = first as? String, let password = second as? String, !ssid.isEmpty, !password.isEmpty {
            return HotspotCredentials(ssid: ssid, password: password)
        }
        let error = [first, second].compactMap { $0 as? NSError }.first
        Log.error("hotspot wake failed: \(error?.localizedDescription ?? "the device answered without a network")")
        return nil
    }
}

/// One browse whose device objects are kept, so one can be woken.
@MainActor
private final class HotspotDeviceBrowse {
    let session: NSObject
    private let list = DeviceObjects()

    private init(session: NSObject) {
        self.session = session
    }

    static func start() -> HotspotDeviceBrowse? {
        guard let session = SharingHotspotBrowser.makeSession() else {
            Log.info("nearby hotspot devices unavailable: SFRemoteHotspotSession is not as measured")
            return nil
        }
        let browse = HotspotDeviceBrowse(session: session)
        _ = session.perform(NSSelectorFromString("setDelegate:"), with: browse.list)
        _ = session.perform(NSSelectorFromString("startBrowsing"))
        return browse
    }

    /// The first list sharingd hands over, or none after `seconds`.
    func devices(within seconds: TimeInterval) async -> [NSObject] {
        let deadline = Date().addingTimeInterval(seconds)
        while list.devices.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return list.devices
    }

    func stop() {
        _ = session.perform(NSSelectorFromString("stopBrowsing"))
        _ = session.perform(NSSelectorFromString("setDelegate:"), with: nil)
    }

    static func name(of device: NSObject) -> String? {
        guard device.responds(to: NSSelectorFromString("deviceName")) else { return nil }
        return device.value(forKey: "deviceName") as? String
    }
}

/// The delegate for `HotspotDeviceBrowse`: keeps sharingd's device
/// objects as they are, since the wake takes one of them.
private final class DeviceObjects: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var found: [NSObject] = []

    var devices: [NSObject] { lock.withLock { found } }

    @objc(session:updatedFoundDevices:)
    func session(_ session: AnyObject, updatedFoundDevices list: NSArray) {
        let objects = list.compactMap { $0 as? NSObject }
        lock.withLock { found = objects }
    }
}

/// Resumes a continuation once, whichever comes first: the device's
/// answer or the timeout.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    /// True when this call resumed it.
    @discardableResult
    func resume(_ value: T) -> Bool {
        guard let continuation = lock.withLock({ () -> CheckedContinuation<T, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }) else { return false }
        continuation.resume(returning: value)
        return true
    }
}

/// Test double: the devices near and what waking each hands over are set
/// by the test, and every wake is recorded.
final class FakeHotspotWaker: HotspotWaking, @unchecked Sendable {
    private let lock = NSLock()
    private var _near: [String] = []
    private var _answers: [String: HotspotCredentials] = [:]
    private var _woken: [String] = []

    var near: [String] {
        get { lock.withLock { _near } }
        set { lock.withLock { _near = newValue } }
    }
    /// What waking each device hands over; a device absent answers nil.
    var answers: [String: HotspotCredentials] {
        get { lock.withLock { _answers } }
        set { lock.withLock { _answers = newValue } }
    }
    var woken: [String] { lock.withLock { _woken } }

    @MainActor
    func nearbyNames() async -> [String] { near }

    @MainActor
    func wake(_ name: String) async -> HotspotCredentials? {
        lock.withLock {
            _woken.append(name)
            guard let device = _near.first(where: { HotspotSSID.matches($0, name) }) else { return nil }
            return _answers[device]
        }
    }
}
