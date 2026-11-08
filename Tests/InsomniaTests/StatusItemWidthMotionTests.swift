import AppKit
import SwiftUI
import XCTest
@testable import Insomnia

final class StatusItemWidthMotionTests: XCTestCase {
    @MainActor
    func testChangingPresentationFinishesDefaultReservationBeforeHidingItsReveal() async throws {
        try XCTSkipIf(Motion.reduceMotion, "requires an in-flight width reveal")
        _ = NSApplication.shared
        for mode in [Config.MenuBarMode.compact, .minimal] {
            let h = Harness()
            defer { h.home.destroy() }
            let manager = h.makeManager()
            let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
            let motion = try XCTUnwrap(controller.model.widthMotion)
            controller.expand(mode: .start)
            try? await Task.sleep(for: .milliseconds(150))
            XCTAssertGreaterThan(controller.widthTarget, 32)
            controller.collapse()
            let deadline = Date().addingTimeInterval(2)
            while motion.reservedWidth == motion.displayedWidth && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertGreaterThan(motion.reservedWidth, motion.displayedWidth, "closing keeps native room during the eye's return")

            manager.config.menuBarMode = mode
            controller.synchronizePresentation()
            XCTAssertEqual(motion.reservedWidth, controller.widthTarget, "the new mode cannot inherit an old translation")
            XCTAssertEqual(motion.displayedWidth, controller.widthTarget)
            try? await Task.sleep(for: .seconds(motion.settleDuration + 0.05))
            XCTAssertEqual(motion.reservedWidth, 32)
            XCTAssertEqual(motion.displayedWidth, 32)
        }
    }

    /// Sample presentation values during the motion, rather than only its
    /// endpoints: a change to the native reservation must never move the eye.
    func testRevealKeepsTheSameScreenPositionAcrossReservationChanges() {
        let rightEdge: CGFloat = 600
        for displayed: CGFloat in [32, 57.5, 99, 148.25, 192] {
            var positions: [CGFloat] = []
            for reserved: CGFloat in [32, 110, 192, 250] {
                var effect = StatusItemRevealEffect(reservedWidth: reserved, displayedWidth: 0)
                effect.animatableData = displayed
                let transform = effect.effectValue(size: CGSize(width: reserved, height: 24))
                positions.append(rightEdge - reserved + transform.m31)
                XCTAssertEqual(effect.reservedWidth, reserved, "animating the reveal never interpolates the native reservation")
            }
            for position in positions {
                XCTAssertEqual(position, rightEdge - displayed, accuracy: 0.001)
            }
        }
    }

    @MainActor
    func testFirstLayoutWritesImmediatelyAndGrowthWritesOnlyOnce() async {
        var writes: [CGFloat] = []
        let motion = StatusItemWidthMotion(writer: StatusWidthWriter { writes.append($0) }, duration: 0.03)

        motion.retarget(32, reduceMotion: false)
        XCTAssertEqual(motion.reservedWidth, 32)
        XCTAssertEqual(motion.displayedWidth, 32)
        XCTAssertEqual(writes, [32])

        motion.retarget(192, reduceMotion: false)
        XCTAssertEqual(motion.reservedWidth, 192, "room is reserved before the reveal begins")
        XCTAssertEqual(motion.displayedWidth, 192)
        XCTAssertEqual(writes, [32, 192])
        motion.retarget(192, reduceMotion: false)
        try? await Task.sleep(for: .seconds(motion.settleDuration + 0.05))
        XCTAssertEqual(writes, [32, 192], "animation and repeated layout reports do not resize the system item")
    }

    @MainActor
    func testShrinkKeepsTheReservationUntilTheReturnMotionFinishes() async {
        var writes: [CGFloat] = []
        let motion = StatusItemWidthMotion(writer: StatusWidthWriter { writes.append($0) }, duration: 0.03)
        motion.retarget(192, reduceMotion: false)

        motion.retarget(32, reduceMotion: false)
        XCTAssertEqual(motion.reservedWidth, 192, "the eye still has room to move toward its compact position")
        XCTAssertEqual(motion.displayedWidth, 32)
        XCTAssertEqual(writes, [192], "the window cannot shrink before the content arrives")

        try? await Task.sleep(for: .seconds(motion.settleDuration + 0.05))
        XCTAssertEqual(motion.reservedWidth, 32)
        XCTAssertEqual(motion.displayedWidth, 32)
        XCTAssertEqual(writes, [192, 32])
    }

    @MainActor
    func testReopeningInsideTheReservedWidthCancelsThePendingShrink() async {
        var writes: [CGFloat] = []
        let motion = StatusItemWidthMotion(writer: StatusWidthWriter { writes.append($0) }, duration: 0.03)
        motion.retarget(192, reduceMotion: false)
        motion.retarget(32, reduceMotion: false)

        // The native width is already 192, but the visible position still
        // needs to reverse. Deduplicating only native writes would miss it.
        motion.retarget(192, reduceMotion: false)
        XCTAssertEqual(motion.reservedWidth, 192)
        XCTAssertEqual(motion.displayedWidth, 192)

        try? await Task.sleep(for: .seconds(motion.settleDuration + 0.05))
        XCTAssertEqual(motion.reservedWidth, 192)
        XCTAssertEqual(writes, [192], "an obsolete close must not resize a reopened item")
    }

    @MainActor
    func testANewerShrinkReplacesTheOldLanding() async {
        var writes: [CGFloat] = []
        let motion = StatusItemWidthMotion(writer: StatusWidthWriter { writes.append($0) }, duration: 0.03)
        motion.retarget(192, reduceMotion: false)
        motion.retarget(32, reduceMotion: false)
        motion.retarget(96, reduceMotion: false)

        XCTAssertEqual(motion.reservedWidth, 192)
        XCTAssertEqual(motion.displayedWidth, 96)
        try? await Task.sleep(for: .seconds(motion.settleDuration + 0.05))
        XCTAssertEqual(motion.reservedWidth, 96)
        XCTAssertEqual(writes, [192, 96], "only the current landing is allowed to commit")
    }

    @MainActor
    func testReduceMotionCommitsImmediatelyAndCancelsAPendingShrink() async {
        var writes: [CGFloat] = []
        let motion = StatusItemWidthMotion(writer: StatusWidthWriter { writes.append($0) }, duration: 0.03)
        motion.retarget(192, reduceMotion: true)
        motion.retarget(32, reduceMotion: false)

        // An accessibility change can finish the same pending target.
        motion.retarget(32, reduceMotion: true)
        XCTAssertEqual(motion.reservedWidth, 32)
        XCTAssertEqual(motion.displayedWidth, 32)
        XCTAssertEqual(writes, [192, 32])

        motion.retarget(192, reduceMotion: true)
        XCTAssertEqual(motion.reservedWidth, 192)
        XCTAssertEqual(motion.displayedWidth, 192)
        try? await Task.sleep(for: .seconds(motion.settleDuration + 0.05))
        XCTAssertEqual(writes, [192, 32, 192], "the previous animated close cannot commit later")
    }
}
