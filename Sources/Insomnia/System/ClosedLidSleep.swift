import Foundation
import IOKit
import IOKit.pwr_mgt

/// Puts a closed Mac to sleep after a timer or floor-rule end (spec section 6).
protocol ClosedLidSleeping: Sendable {
    /// `IOPMSleepSystem`. No root needed. macOS refuses it while sleep is
    /// disabled.
    func requestSleep() throws
}

struct ClosedLidSleepError: Error, LocalizedError {
    let call: String
    let code: IOReturn

    var errorDescription: String? {
        "\(call) returned \(String(format: "0x%08x", UInt32(bitPattern: code)))"
    }
}

struct IOKitClosedLidSleep: ClosedLidSleeping {
    func requestSleep() throws {
        let connect = IOPMFindPowerManagement(kIOMainPortDefault)
        guard connect != 0 else {
            throw ClosedLidSleepError(call: "IOPMFindPowerManagement", code: kIOReturnNotFound)
        }
        defer { IOServiceClose(connect) }
        let result = IOPMSleepSystem(connect)
        guard result == kIOReturnSuccess else {
            throw ClosedLidSleepError(call: "IOPMSleepSystem", code: result)
        }
    }
}

struct NoopClosedLidSleep: ClosedLidSleeping {
    func requestSleep() throws {}
}
