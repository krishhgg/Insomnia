import SwiftUI
import XCTest
@testable import Insomnia

@MainActor
final class AutoEyeBlinkTests: XCTestCase {
    private enum Stop: Error { case finished }

    func testOnlyArmedAutoLoopsAndReduceMotionSuppressesIt() {
        XCTAssertTrue(AutoEyeBlink.enabled(armed: true, reduceMotion: false))
        XCTAssertFalse(AutoEyeBlink.enabled(armed: false, reduceMotion: false))
        XCTAssertFalse(AutoEyeBlink.enabled(armed: true, reduceMotion: true))
        XCTAssertFalse(AutoEyeBlink.enabled(armed: false, reduceMotion: true))
    }

    func testAutoLetsTheNormalEyeSpringsFullySettleBeforeChangingDirection() {
        XCTAssertGreaterThanOrEqual(Motion.autoBlinkCloseDuration,
            Spring(response: Motion.blinkCloseResponse, dampingRatio: Motion.blinkCloseDampingFraction).settlingDuration)
        XCTAssertGreaterThanOrEqual(Motion.autoBlinkOpenDuration,
            Spring(response: Motion.blinkResponse, dampingRatio: Motion.blinkDampingFraction).settlingDuration)
    }

    func testArmedEyeDefaultsOpenAndReduceMotionKeepsItOpen() {
        XCTAssertTrue(AutoEyeBlink.displayOpen(armed: true, reduceMotion: false, blinkOpen: true, fallbackOpen: false))
        XCTAssertFalse(AutoEyeBlink.displayOpen(armed: true, reduceMotion: false, blinkOpen: false, fallbackOpen: true))
        XCTAssertTrue(AutoEyeBlink.displayOpen(armed: true, reduceMotion: true, blinkOpen: false, fallbackOpen: false))
        XCTAssertFalse(AutoEyeBlink.displayOpen(armed: false, reduceMotion: false, blinkOpen: true, fallbackOpen: false))
        XCTAssertTrue(AutoEyeBlink.displayOpen(armed: false, reduceMotion: true, blinkOpen: false, fallbackOpen: true))
    }

    func testEachCloseOpenCycleRestsOpenForThreeSeconds() async {
        var frames: [Bool] = []
        var waits: [Duration] = []
        do {
            try await AutoEyeBlink.run(sleep: { duration in
                waits.append(duration)
                if waits.count == 6 { throw Stop.finished }
            }, setOpen: { frames.append($0) })
            XCTFail("unbounded loop unexpectedly returned")
        } catch Stop.finished {
            XCTAssertEqual(frames, [true, false, true, false, true])
            XCTAssertEqual(waits, [
                .seconds(3), .seconds(Motion.autoBlinkCloseDuration), .seconds(Motion.autoBlinkOpenDuration),
                .seconds(3), .seconds(Motion.autoBlinkCloseDuration), .seconds(Motion.autoBlinkOpenDuration),
            ])
            XCTAssertGreaterThan(Motion.autoBlinkOpenDuration, Motion.blinkResponse)
            XCTAssertGreaterThan(Motion.autoBlinkCloseDuration, Motion.blinkCloseResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCancellationCannotWriteAnotherFrameEvenIfSleepIgnoresCancellation() async {
        for stopAt in 1...3 {
            var frames: [Bool] = []
            var sleeps = 0
            let gate = AsyncGate()
            let task = Task {
                try await AutoEyeBlink.run(sleep: { _ in
                    sleeps += 1
                    if sleeps == stopAt { await gate.wait() }
                }, setOpen: { frames.append($0) })
            }
            await gate.waitUntilStarted()
            task.cancel()
            await gate.open()
            switch await task.result {
            case .success: XCTFail("cancelled loop should throw")
            case let .failure(error): XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(frames, Array([true, false, true].prefix(stopAt)),
                           "a cancelled old loop must not retarget a replacement loop's eye")
            XCTAssertEqual(sleeps, stopAt)
        }
    }

    func testCancelledBeforeStartDoesNotOpenOrScheduleASleep() async {
        let gate = AsyncGate()
        var frames: [Bool] = []
        var sleeps = 0
        let task = Task {
            await gate.wait()
            try await AutoEyeBlink.run(sleep: { _ in sleeps += 1 }, setOpen: { frames.append($0) })
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.open()
        switch await task.result {
        case .success: XCTFail("cancelled loop should throw")
        case let .failure(error): XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(sleeps, 0)
    }
}
