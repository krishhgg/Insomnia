import Foundation
import XCTest
@testable import Insomnia

final class ShellTimeoutTests: XCTestCase, @unchecked Sendable {
    func testSignalBeforeDeadlineIsNotATimeout() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "kill -TERM $$"], timeout: 5)
        XCTAssertEqual(result.status, SIGTERM)
        XCTAssertFalse(result.succeeded)
    }

    func testNormalExitPreservesStatusAndOutput() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "printf output; printf error >&2; exit 7"], timeout: 5)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.stdout, "output")
        XCTAssertEqual(result.stderr, "error")
    }

    func testSuccessfulExitIsNotATimeout() async throws {
        let result = try await Shell.run("/usr/bin/true", [], timeout: 5)
        XCTAssertTrue(result.succeeded)
    }

    func testDeadlineTerminatesRunningChild() async throws {
        do {
            _ = try await Shell.run("/bin/sleep", ["30"], timeout: 0.2)
            XCTFail("Expected a timeout")
        } catch let ShellTimeoutError.timedOut(exe, seconds) {
            XCTAssertEqual(exe, "/bin/sleep")
            XCTAssertEqual(seconds, 0.2)
        }
    }

    func testDeadlineIsATimeoutEvenWhenChildHandlesTermAndExitsSuccessfully() async throws {
        do {
            _ = try await Shell.run("/bin/sh", ["-c", "trap 'exit 0' TERM; while :; do /bin/sleep 0.01; done"], timeout: 0.5)
            XCTFail("A child that exits successfully after the deadline still timed out")
        } catch let ShellTimeoutError.timedOut(exe, seconds) {
            XCTAssertEqual(exe, "/bin/sh")
            XCTAssertEqual(seconds, 0.5)
        }
    }

    func testDeadlineKillsChildThatIgnoresTerm() async throws {
        do {
            _ = try await Shell.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 30"], timeout: 0.5)
            XCTFail("Expected a timeout after SIGKILL")
        } catch let ShellTimeoutError.timedOut(exe, seconds) {
            XCTAssertEqual(exe, "/bin/sh")
            XCTAssertEqual(seconds, 0.5)
        }
    }
}
