import Darwin
import Foundation
import XCTest
@testable import Insomnia

final class HotspotUsageTests: XCTestCase {
    private func sample(_ received: UInt64, _ sent: UInt64 = 0, at: TimeInterval = 0, index: UInt32 = 1) -> InterfaceByteSample {
        InterfaceByteSample(interfaceIndex: index, received: received, sent: sent, timestamp: at)
    }

    private func tracker(budget: UInt64 = 1_000) -> HotspotUsageTracker {
        HotspotUsageTracker(ledger: HotspotUsageLedger(budgetBytes: budget))
    }

    func testFirstSampleDoesNotIncludeTrafficFromBeforeTracking() {
        var t = tracker()
        XCTAssertEqual(t.record(sample(100_000, 50_000), connection: .configuredHotspot), [])
        XCTAssertEqual(t.ledger.total, 0)
    }

    func testCountsUploadAndDownloadOnlyOnConfiguredHotspot() {
        var t = tracker()
        _ = t.record(sample(100, 200), connection: .configuredHotspot)
        _ = t.record(sample(150, 230, at: 5), connection: .configuredHotspot)
        XCTAssertEqual(t.ledger.received, 50)
        XCTAssertEqual(t.ledger.sent, 30)
        _ = t.record(sample(9_000, 9_000, at: 10), connection: .otherNetwork)
        _ = t.record(sample(12_000, 12_000, at: 15), connection: .configuredHotspot)
        XCTAssertEqual(t.ledger.total, 80)
        _ = t.record(sample(12_020, 12_030, at: 20), connection: .configuredHotspot)
        XCTAssertEqual(t.ledger.total, 130)
    }

    func testWarnsAtExactly80PercentAnd100PercentOnce() {
        var t = tracker()
        _ = t.record(sample(0), connection: .configuredHotspot)
        XCTAssertEqual(t.record(sample(799, at: 1), connection: .configuredHotspot), [])
        XCTAssertEqual(t.record(sample(800, at: 2), connection: .configuredHotspot), [.approaching])
        XCTAssertEqual(t.record(sample(900, at: 3), connection: .configuredHotspot), [])
        XCTAssertEqual(t.record(sample(1_000, at: 4), connection: .configuredHotspot), [.reached])
        XCTAssertEqual(t.record(sample(1_200, at: 5), connection: .configuredHotspot), [])
        XCTAssertEqual(t.ledger.total, 1_200, "A warning is not a hard traffic cap")
    }

    func testJumpPastBothLevelsProducesOnlyReachedWarning() {
        var t = tracker()
        _ = t.record(sample(0), connection: .configuredHotspot)
        XCTAssertEqual(t.record(sample(1_200, at: 1), connection: .configuredHotspot), [.reached])
        XCTAssertEqual(t.ledger.warned, [.approaching, .reached])
    }

    func testMissingNameDoesNotCountOrBridgeTheUnknownInterval() {
        var t = tracker()
        _ = t.record(sample(0), connection: .configuredHotspot)
        _ = t.record(sample(100, at: 5), connection: .configuredHotspot)
        XCTAssertEqual(t.record(sample(1_000, at: 10), connection: .unavailable), [])
        _ = t.record(sample(2_000, at: 15), connection: .configuredHotspot)
        XCTAssertEqual(t.ledger.total, 100)
        XCTAssertTrue(t.ledger.hasUnmeasuredIntervals)
    }

    func testFailedCounterReadBreaksBaseline() {
        var t = tracker()
        _ = t.record(sample(0), connection: .configuredHotspot)
        _ = t.record(nil, connection: .configuredHotspot)
        _ = t.record(sample(2_000, at: 10), connection: .configuredHotspot)
        XCTAssertEqual(t.ledger.total, 0)
        XCTAssertTrue(t.ledger.hasUnmeasuredIntervals)
    }

    func testInterfaceChangeDoesNotSubtractDifferentInterfaces() {
        var t = tracker()
        _ = t.record(sample(0, index: 1), connection: .configuredHotspot)
        _ = t.record(sample(9_000, at: 5, index: 2), connection: .configuredHotspot)
        _ = t.record(sample(9_100, at: 10, index: 2), connection: .configuredHotspot)
        XCTAssertEqual(t.ledger.total, 100)
        XCTAssertTrue(t.ledger.hasUnmeasuredIntervals)
    }

    func testResetOfEitherCounterDoesNotInventAUInt64Wrap() {
        for next in [sample(10, 600, at: 5), sample(600, 10, at: 5)] {
            var t = tracker()
            _ = t.record(sample(500, 500), connection: .configuredHotspot)
            _ = t.record(next, connection: .configuredHotspot)
            XCTAssertEqual(t.ledger.total, 0)
            XCTAssertTrue(t.ledger.hasUnmeasuredIntervals)
        }
    }

    func testSleepOrLongSamplingGapIsNotAttributedToHotspot() {
        var t = tracker()
        _ = t.record(sample(0), connection: .configuredHotspot)
        _ = t.record(sample(9_000, at: 60), connection: .configuredHotspot)
        _ = t.record(sample(9_100, at: 65), connection: .configuredHotspot)
        XCTAssertEqual(t.ledger.total, 100)
        XCTAssertTrue(t.ledger.hasUnmeasuredIntervals)
    }

    func testInvalidTimestampsDoNotCount() {
        for at in [TimeInterval.nan, .infinity, 0, -1] {
            var t = tracker()
            _ = t.record(sample(0), connection: .configuredHotspot)
            _ = t.record(sample(1_000, at: at), connection: .configuredHotspot)
            XCTAssertEqual(t.ledger.total, 0)
            XCTAssertTrue(t.ledger.hasUnmeasuredIntervals)
        }
    }

    func testStopKeepsTotalButNeverCountsInactiveTraffic() {
        var t = tracker()
        _ = t.record(sample(0), connection: .configuredHotspot)
        _ = t.record(sample(100, at: 5), connection: .configuredHotspot)
        t.stop()
        _ = t.record(sample(10_000, at: 10), connection: .configuredHotspot)
        XCTAssertEqual(t.ledger.total, 100)
        _ = t.record(sample(10_100, at: 15), connection: .configuredHotspot)
        XCTAssertEqual(t.ledger.total, 200)
    }

    func testSavedLedgerKeepsTotalsAndWarningsWithoutOldBaseline() throws {
        var t = tracker()
        _ = t.record(sample(0), connection: .configuredHotspot)
        _ = t.record(sample(800, at: 5), connection: .configuredHotspot)
        let data = try JSONEncoder().encode(t.ledger)
        let saved = try JSONDecoder().decode(HotspotUsageLedger.self, from: data)
        XCTAssertEqual(saved, t.ledger)
        var relaunched = HotspotUsageTracker(ledger: saved)
        XCTAssertEqual(relaunched.record(sample(50_000), connection: .configuredHotspot), [])
        XCTAssertEqual(relaunched.ledger.total, 800)
        XCTAssertEqual(relaunched.record(sample(50_200, at: 5), connection: .configuredHotspot), [.reached])
    }

    func testExplicitResetStartsNewTotalsAndWarningHistory() {
        var t = tracker()
        _ = t.record(sample(0), connection: .configuredHotspot)
        _ = t.record(sample(1_000, at: 5), connection: .configuredHotspot)
        t.reset()
        XCTAssertEqual(t.ledger, HotspotUsageLedger(budgetBytes: 1_000))
        _ = t.record(sample(50_000, at: 10), connection: .configuredHotspot)
        XCTAssertEqual(t.ledger.total, 0)
        XCTAssertEqual(t.record(sample(50_800, at: 15), connection: .configuredHotspot), [.approaching])
    }

    func testBudgetEditKeepsBytesAndWarnsForTheNewBudget() {
        var t = tracker()
        _ = t.record(sample(0), connection: .configuredHotspot)
        _ = t.record(sample(800, at: 5), connection: .configuredHotspot)
        XCTAssertEqual(t.setBudget(2_000), [])
        XCTAssertEqual(t.ledger.total, 800)
        XCTAssertEqual(t.setBudget(500), [.reached])
        XCTAssertEqual(t.setBudget(500), [])
    }

    func testZeroBudgetDisablesWarningsWithoutDisablingAccounting() {
        var t = tracker(budget: 0)
        _ = t.record(sample(0), connection: .configuredHotspot)
        XCTAssertEqual(t.record(sample(1_000, at: 5), connection: .configuredHotspot), [])
        XCTAssertEqual(t.ledger.total, 1_000)
    }

    func testOddBudgetThresholdRoundsUpToWholeByte() {
        var t = tracker(budget: 7)
        _ = t.record(sample(0), connection: .configuredHotspot)
        XCTAssertEqual(t.record(sample(5, at: 1), connection: .configuredHotspot), [])
        XCTAssertEqual(t.record(sample(6, at: 2), connection: .configuredHotspot), [.approaching])
    }

    func testVeryLargeAmountsNeverOverflowOrLose64BitPrecision() {
        var t = tracker(budget: .max)
        _ = t.record(sample(0), connection: .configuredHotspot)
        XCTAssertEqual(t.record(sample(.max, .max, at: 5), connection: .configuredHotspot), [.reached])
        XCTAssertEqual(t.ledger.total, .max)
        XCTAssertEqual(t.ledger.received, .max)
        XCTAssertEqual(t.ledger.sent, .max)
    }
}

final class InterfaceByteCounterTests: XCTestCase {
    private func message(index: UInt16 = 1, received: UInt64 = 0, sent: UInt64 = 0) -> Data {
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_version = UInt8(RTM_VERSION)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_index = index
        header.ifm_data.ifi_ibytes = received
        header.ifm_data.ifi_obytes = sent
        return withUnsafeBytes(of: &header) { Data($0) }
    }

    func testReads64BitCountersForOnlyRequestedInterface() throws {
        let data = message(index: 2, received: 100) + message(received: 9_000_000_123, sent: 5_000_000_321)
        let value = try InterfaceByteCounters.decode(data, index: 1, timestamp: 5)
        XCTAssertEqual(value, InterfaceByteSample(interfaceIndex: 1, received: 9_000_000_123, sent: 5_000_000_321, timestamp: 5))
    }

    func testMalformedLengthsNeverReadBeyondBuffer() {
        for data in [Data([1, 2]), Data([0, 0, 0, 0]), Data([255, 255, 0, 0]), Data([4, 0, UInt8(RTM_VERSION), UInt8(RTM_IFINFO2)]), message().dropLast()] {
            XCTAssertThrowsError(try InterfaceByteCounters.decode(Data(data), index: 1, timestamp: 0))
        }
    }

    func testUnknownMessageIsSkippedAndBadVersionIsRefused() throws {
        let prefix = Data([4, 0, UInt8(RTM_VERSION), 0])
        XCTAssertEqual(try InterfaceByteCounters.decode(prefix + message(received: 100), index: 1, timestamp: 0).received, 100)
        var bad = message()
        bad[2] = 0
        XCTAssertThrowsError(try InterfaceByteCounters.decode(bad, index: 1, timestamp: 0))
    }

    func testMissingInterfaceIsAnErrorNotZeroUsage() {
        XCTAssertThrowsError(try InterfaceByteCounters.decode(message(index: 2), index: 1, timestamp: 0))
        XCTAssertThrowsError(try InterfaceByteCounters.read(interfaceName: "insomnia-missing-fixture", timestamp: 0))
    }
}
