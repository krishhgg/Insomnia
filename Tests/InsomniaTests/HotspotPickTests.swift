import XCTest
@testable import Insomnia

final class HotspotPickTests: XCTestCase {
    func testNoScanResultsPicksNothing() {
        XCTAssertNil(HotspotPick.choose(protected: [], rssi: []))
    }

    func testAnOpenLookalikeIsRefused() {
        XCTAssertNil(HotspotPick.choose(protected: [false], rssi: [-30]))
    }

    func testTheProtectedNetworkIsPickedOverAStrongerOpenLookalike() {
        XCTAssertEqual(HotspotPick.choose(protected: [false, true], rssi: [-30, -70]), 1)
    }

    func testTheStrongestProtectedNetworkIsPicked() {
        XCTAssertEqual(HotspotPick.choose(protected: [true, true, false], rssi: [-80, -40, -20]), 1)
    }
}
