import CoreWLAN
import Foundation
import SystemConfiguration

struct HotspotUsageReading: Sendable {
    let ssid: String?
    let sample: InterfaceByteSample?
}

protocol HotspotUsageSampling: Sendable {
    func read() async -> HotspotUsageReading
}

struct WiFiUsageSampler: HotspotUsageSampling {
    func read() async -> HotspotUsageReading {
        await Task.detached(priority: .utility) {
            let client = CWWiFiClient()
            guard let wifi = client.interface(), let name = wifi.interfaceName,
                  let ssid = wifi.ssid() else { return HotspotUsageReading(ssid: nil, sample: nil) }
            let sample = try? InterfaceByteCounters.read(interfaceName: name, timestamp: Date().timeIntervalSince1970)
            // Do not attribute a reading taken during an association change.
            guard wifi.ssid() == ssid else { return HotspotUsageReading(ssid: nil, sample: nil) }
            return HotspotUsageReading(ssid: ssid, sample: sample)
        }.value
    }
}

@MainActor
protocol HotspotUsageObserving: AnyObject {
    func start(changed: @escaping @MainActor () -> Void, unavailable: @escaping @MainActor () -> Void) throws
    func stop()
}

/// Public dynamic-store notifications work with the app's ad-hoc signature.
/// AirPort and link state changes invalidate even a reading in flight.
@MainActor
final class WiFiUsageObserver: HotspotUsageObserving {
    private var store: SCDynamicStore?
    private var callbacks: Callbacks?
    enum Failure: Error { case unavailable }

    // SCDynamicStore retains the context, including during callback delivery.
    // Closures capture the driver weakly; stopping also disables this box so
    // an already queued callback cannot reach a newly configured session.
    final class Callbacks: Sendable {
        let changed: @MainActor () -> Void
        let unavailable: @MainActor () -> Void
        @MainActor var enabled = true
        init(changed: @escaping @MainActor () -> Void, unavailable: @escaping @MainActor () -> Void) {
            self.changed = changed
            self.unavailable = unavailable
        }
    }

    // Context lifetime callbacks may run on any SystemConfiguration queue.
    // Define them outside the main-actor start() body so Swift does not add
    // an actor executor check to these C callbacks.
    nonisolated static func context(for callbacks: Callbacks) -> SCDynamicStoreContext {
        SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(callbacks).toOpaque(), retain: { info in
            _ = Unmanaged<Callbacks>.fromOpaque(info).retain()
            return info
        }, release: { info in
            Unmanaged<Callbacks>.fromOpaque(info).release()
        }, copyDescription: nil)
    }

    nonisolated private static var notificationCallback: SCDynamicStoreCallBack {
        { _, keys, info in
            guard let info else { return }
            let callbacks = Unmanaged<Callbacks>.fromOpaque(info).takeUnretainedValue()
            let restarted = CFArrayGetCount(keys) == 0
            // Only notification delivery uses the dispatch queue registered below.
            MainActor.assumeIsolated {
                guard callbacks.enabled else { return }
                // Apple's callback contract identifies a configd restart by
                // an empty key list: discard assumptions and reconnect.
                if restarted { callbacks.unavailable() }
                else { callbacks.changed() }
            }
        }
    }

    func start(changed: @escaping @MainActor () -> Void, unavailable: @escaping @MainActor () -> Void) throws {
        stop()
        let callbacks = Callbacks(changed: changed, unavailable: unavailable)
        var context = Self.context(for: callbacks)
        guard let store = SCDynamicStoreCreate(nil, "Insomnia hotspot usage" as CFString, Self.notificationCallback, &context),
              SCDynamicStoreSetNotificationKeys(store, nil, ["State:/Network/Interface/[^/]+/(AirPort|Link|IPv4|IPv6)$"] as CFArray),
              SCDynamicStoreSetDispatchQueue(store, .main) else {
            throw Failure.unavailable
        }
        self.callbacks = callbacks
        self.store = store
    }

    func stop() {
        callbacks?.enabled = false
        if let store { _ = SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil
        callbacks = nil
    }
}
