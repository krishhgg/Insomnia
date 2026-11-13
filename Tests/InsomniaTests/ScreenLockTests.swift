import XCTest
@testable import Insomnia

private enum StubScreenLock {
    static let calls = Locked<Int>(0)
    static let status = Locked<Int32>(0)
}

final class ScreenLockTests: XCTestCase {
    func testSuccessfulResolutionIsLazyAndCached() throws {
        let resolutions = Locked<Int>(0)
        StubScreenLock.calls.value = 0
        StubScreenLock.status.value = 0
        let locker = LoginFrameworkScreenLocker(resolve: {
            resolutions.value += 1
            return .success {
                StubScreenLock.calls.value += 1
                return StubScreenLock.status.value
            }
        })

        XCTAssertEqual(resolutions.value, 0)
        for _ in 0..<3 { try locker.lockNow() }

        XCTAssertEqual(resolutions.value, 1)
        XCTAssertEqual(StubScreenLock.calls.value, 3)
    }

    func testFailedResolutionIsLazyAndCached() {
        for what in ["login.framework could not be loaded", "login.framework has no SACLockScreenImmediate"] {
            let resolutions = Locked<Int>(0)
            let locker = LoginFrameworkScreenLocker(resolve: {
                resolutions.value += 1
                return .failure(ScreenLockError(what: what))
            })

            XCTAssertEqual(resolutions.value, 0)
            for _ in 0..<3 {
                XCTAssertThrowsError(try locker.lockNow()) { error in
                    XCTAssertEqual((error as? ScreenLockError)?.what, what)
                }
            }
            XCTAssertEqual(resolutions.value, 1)
        }
    }

    func testCallFailureDoesNotReplaceTheCachedFunction() throws {
        let resolutions = Locked<Int>(0)
        StubScreenLock.calls.value = 0
        StubScreenLock.status.value = 7
        let locker = LoginFrameworkScreenLocker(resolve: {
            resolutions.value += 1
            return .success {
                StubScreenLock.calls.value += 1
                return StubScreenLock.status.value
            }
        })

        for _ in 0..<3 {
            XCTAssertThrowsError(try locker.lockNow()) { error in
                XCTAssertEqual((error as? ScreenLockError)?.what, "SACLockScreenImmediate returned 7")
            }
        }
        StubScreenLock.status.value = 0
        try locker.lockNow()

        XCTAssertEqual(resolutions.value, 1)
        XCTAssertEqual(StubScreenLock.calls.value, 4)
    }
}
