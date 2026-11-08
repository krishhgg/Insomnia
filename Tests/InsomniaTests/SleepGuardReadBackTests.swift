import XCTest
@testable import Insomnia

/// `pmset -a disablesleep 1` exiting 0 does not prove that sleep is disabled:
/// another process can put SleepDisabled back to 0 a moment later, as a
/// keep-awake LaunchDaemon did every 2 s on one Mac. `sudo` and `pmset` are tiny `/bin/sh` scripts in a
/// private temp dir that record their calls, so nothing here runs sudo or
/// pmset or changes a power setting.
final class SleepGuardReadBackTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-readback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String) -> String { dir.appendingPathComponent(name).path }

    private func script(_ name: String, _ body: String) throws -> String {
        let path = file(name)
        try TestScripts.write("#!/bin/sh\n\(body)\n", to: URL(fileURLWithPath: path))
        return path
    }

    private static func append(_ text: String, to path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// A sudo that exits 0, and a pmset whose `-g` reads SleepDisabled 1
    /// until the settle wait has run, as on that Mac, then prints `afterSettle`
    /// and exits `status` (to stderr when `status` is not 0). The wait does
    /// not sleep: it records `wait <seconds>` and marks the time as passed.
    /// All three append to `calls`.
    private func fakeGuard(afterSettle output: String, status: Int32 = 0) throws -> PmsetSleepGuard {
        let calls = file("calls")
        let settled = file("settled")
        try output.write(toFile: file("after"), atomically: true, encoding: .utf8)
        let sudo = try script("sudo", "printf 'sudo %s\\n' \"$*\" >> '\(calls)'")
        let pmset = try script("pmset", """
        printf 'pmset %s\\n' "$*" >> '\(calls)'
        if [ -e '\(settled)' ]; then
            cat '\(file("after"))' >&\(status == 0 ? 1 : 2)
            exit \(status)
        fi
        printf 'System-wide power settings:\\n SleepDisabled\\t\\t1\\n'
        """)
        return PmsetSleepGuard(sudo: sudo, pmset: pmset, timeout: 5, stopGrace: 1, settleWait: { seconds in
            try Self.append("wait \(seconds)\n", to: calls)
            FileManager.default.createFile(atPath: settled, contents: nil)
        })
    }

    private func sleepDisabled(_ value: String) -> String {
        "System-wide power settings:\n SleepDisabled\t\t\(value)\n"
    }

    private func calls() throws -> [String] {
        try String(contentsOfFile: file("calls"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    /// The disable, the wait, then the read: a read before the wait would
    /// see the 1 that macOS has not put back yet.
    private var expectedCalls: [String] {
        ["sudo -n \(file("pmset")) -a disablesleep 1", "wait 5.0", "pmset -g"]
    }

    private func disableSleep(_ sleepGuard: PmsetSleepGuard) async throws {
        let lock = RecoveryLock(url: dir.appendingPathComponent(".recovery.lock"))
        let handle = try XCTUnwrap(try lock.tryAcquire())
        defer { handle.release() }
        try await RecoveryLock.$held.withValue(handle) { try await sleepGuard.setSleepDisabled(true) }
    }

    /// pmset exits 0 and the bit reads 1, but it reads 0 after the settle
    /// time. The disable throws, so the start fails like any failed pmset
    /// instead of running a session that a closed lid ends in sleep.
    func testDisableThatMacOSPutsBackThrows() async throws {
        let sleepGuard = try fakeGuard(afterSettle: sleepDisabled("0"))
        do {
            try await disableSleep(sleepGuard)
            XCTFail("a disable that was put back returned")
        } catch let error as SleepDisableRevertedError {
            XCTAssertEqual(error.localizedDescription, "SleepDisabled read 0 again within 5 s of `pmset -a disablesleep 1`; another process may be resetting it, so closing the lid would still sleep this Mac")
        }
        XCTAssertEqual(try calls(), expectedCalls)
    }

    func testDisableThatHoldsReturnsAfterReadingItBack() async throws {
        let sleepGuard = try fakeGuard(afterSettle: sleepDisabled("1"))
        try await disableSleep(sleepGuard)
        XCTAssertEqual(try calls(), expectedCalls)
    }

    /// Output with no SleepDisabled 0 or 1 is not proof that the bit was put
    /// back. The disable still throws, but says the read failed.
    func testUnreadableReadBackIsAReadErrorNotARevert() async throws {
        for output in ["System-wide power settings:\n standby 1\n", "", sleepDisabled("2")] {
            try? FileManager.default.removeItem(atPath: file("calls"))
            try? FileManager.default.removeItem(atPath: file("settled"))
            let sleepGuard = try fakeGuard(afterSettle: output)
            do {
                try await disableSleep(sleepGuard)
                XCTFail("an unreadable read back returned for \(output.debugDescription)")
            } catch let error as SleepGuardError {
                XCTAssertEqual(error.localizedDescription, "`pmset -g` failed with status 0: no SleepDisabled line reading 0 or 1, so `pmset -a disablesleep 1` could not be read back")
            }
            XCTAssertEqual(try calls(), expectedCalls)
        }
    }

    func testFailedReadBackThrowsPmsetsError() async throws {
        let sleepGuard = try fakeGuard(afterSettle: "pmset: cannot read settings\n", status: 3)
        do {
            try await disableSleep(sleepGuard)
            XCTFail("a failed read back returned")
        } catch let error as SleepGuardError {
            XCTAssertEqual(error.localizedDescription, "`pmset -g` failed with status 3: pmset: cannot read settings")
        }
        XCTAssertEqual(try calls(), expectedCalls)
    }
}
