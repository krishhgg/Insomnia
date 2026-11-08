import XCTest
@testable import Insomnia

final class PmsetParsingTests: XCTestCase {
    let withFlag = """
    System-wide power settings:
    Currently in use:
     standby              1
     Sleep On Power Button 1
     SleepDisabled        1
     hibernatefile        /var/vm/sleepimage
     powernap             0
     lidwake              1
     disksleep            10
     sleep                1 (sleep prevented by powerd, coreaudiod)
     displaysleep         10
    """

    let withoutFlag = """
    System-wide power settings:
    Currently in use:
     standby              1
     Sleep On Power Button 1
     hibernatefile        /var/vm/sleepimage
     powernap             0
     lidwake              1
     disksleep            10
     sleep                1
     displaysleep         10
    """

    let zeroFlag = """
    Currently in use:
     SleepDisabled        0
     sleep                1
    """

    func testDetectsSleepDisabledOne() {
        XCTAssertTrue(PmsetSleepGuard.parseSleepDisabled(withFlag))
    }

    func testAbsentFlagIsFalse() {
        XCTAssertFalse(PmsetSleepGuard.parseSleepDisabled(withoutFlag))
    }

    func testZeroFlagIsFalse() {
        XCTAssertFalse(PmsetSleepGuard.parseSleepDisabled(zeroFlag))
    }

    func testEmptyOutputIsFalse() {
        XCTAssertFalse(PmsetSleepGuard.parseSleepDisabled(""))
    }

    func testDoesNotMatchSubstringsOfOtherKeys() {
        XCTAssertFalse(PmsetSleepGuard.parseSleepDisabled(" SleepDisabledFoo 1\n"))
        XCTAssertFalse(PmsetSleepGuard.parseSleepDisabled(" sleep 1\n"))
    }

    func testTabSeparated() {
        XCTAssertTrue(PmsetSleepGuard.parseSleepDisabled("SleepDisabled\t1\n"))
    }

    func testErrorMessageMentionsInstall() {
        let e = SleepGuardError(command: "sudo -n pmset -a disablesleep 1", status: 1, stderr: "sudo: a password is required\n")
        let msg = e.errorDescription ?? ""
        XCTAssertTrue(msg.contains("disablesleep 1"))
        XCTAssertTrue(msg.contains("password is required"))
        XCTAssertTrue(msg.contains("install.sh"))
    }

    // Real `pmset -g custom` shape on a MacBook: one block per power source.
    let custom = """
    Battery Power:
     lidwake              1
     lowpowermode         1
     standbydelayhigh     86400
     sleep                1
    AC Power:
     lidwake              1
     lowpowermode         0
     sleep                1
    """

    func testLowPowerModeIsReadFromTheBatterySectionOnly() {
        XCTAssertEqual(PmsetSleepGuard.parseLowPowerMode(custom), true)
        let swapped = custom.replacingOccurrences(of: "lowpowermode         1", with: "lowpowermode         X")
            .replacingOccurrences(of: "lowpowermode         0", with: "lowpowermode         1")
            .replacingOccurrences(of: "lowpowermode         X", with: "lowpowermode         0")
        XCTAssertEqual(PmsetSleepGuard.parseLowPowerMode(swapped), false, "read the AC value instead of the battery value")
    }

    func testLowPowerModeIsUnknownWithoutABatterySection() {
        XCTAssertNil(PmsetSleepGuard.parseLowPowerMode("AC Power:\n lowpowermode 1\n"))
        XCTAssertNil(PmsetSleepGuard.parseLowPowerMode(""))
    }

    /// Only an explicit 0 or 1 is an answer. Anything else is unknown, and
    /// unknown must not become "off", or Insomnia would take over a mode the
    /// user may have switched on.
    func testLowPowerModeValueMustBeAnExplicitZeroOrOne() {
        XCTAssertEqual(PmsetSleepGuard.parseLowPowerMode("Battery Power:\n lowpowermode 0\n"), false)
        XCTAssertNil(PmsetSleepGuard.parseLowPowerMode("Battery Power:\n lowpowermode 2\n"))
        XCTAssertNil(PmsetSleepGuard.parseLowPowerMode("Battery Power:\n lowpowermode (unknown)\n"), "an unreadable value was taken as proof the mode is off")
    }

    // `pmset -g custom` on macOS 27.0.1 (MacBook Pro, M5 Pro): no
    // `lowpowermode` key, the mode is reported as `powermode`.
    let custom27 = """
    Battery Power:
     lidwake              1
     powermode            1
     sleep                1
    AC Power:
     lidwake              1
     powermode            0
     sleep                1
    """

    func testLowPowerModeIsReadFromPowermodeWhenLowpowermodeIsAbsent() {
        XCTAssertEqual(PmsetSleepGuard.parseLowPowerMode(custom27), true)
        XCTAssertEqual(PmsetSleepGuard.parseLowPowerMode("Battery Power:\n powermode 0\n"), false)
        XCTAssertNil(PmsetSleepGuard.parseLowPowerMode("AC Power:\n powermode 1\n"), "read the AC value instead of the battery value")
        let swapped = custom27.replacingOccurrences(of: "powermode            1", with: "powermode            X")
            .replacingOccurrences(of: "powermode            0", with: "powermode            1")
            .replacingOccurrences(of: "powermode            X", with: "powermode            0")
        XCTAssertEqual(PmsetSleepGuard.parseLowPowerMode(swapped), false, "read the AC value instead of the battery value")
    }

    /// High Power is a preference the user set: it must read as unknown, not
    /// as "off", or the session end's `lowpowermode 0` would replace it.
    func testHighPowerModeIsUnknownNotOff() {
        XCTAssertNil(PmsetSleepGuard.parseLowPowerMode("Battery Power:\n powermode 2\n"))
        XCTAssertNil(PmsetSleepGuard.parseLowPowerMode("Battery Power:\n powermode (unknown)\n"))
    }

    func testLowpowermodeWinsOverPowermode() {
        XCTAssertEqual(PmsetSleepGuard.parseLowPowerMode("Battery Power:\n powermode 0\n lowpowermode 1\n"), true)
        XCTAssertEqual(PmsetSleepGuard.parseLowPowerMode("Battery Power:\n lowpowermode 0\n powermode 1\n"), false)
        XCTAssertNil(PmsetSleepGuard.parseLowPowerMode("Battery Power:\n lowpowermode 2\n powermode 1\n"), "an unreadable lowpowermode fell back to powermode")
        XCTAssertNil(PmsetSleepGuard.parseLowPowerMode("Battery Power:\n lowpowermode\n powermode 0\n"), "a lowpowermode line with no value fell back to powermode")
    }

    /// `pmset -g custom` excerpt from #69 (macOS 26.7.1, 25G241, MacBook Pro
    /// M4 Pro): 26.7.1 already prints `powermode`, with High Power on AC.
    func testMacOS2671PowermodeIsReadFromTheBatterySection() {
        let custom2671 = """
        Battery Power:
         powermode            0
        AC Power:
         powermode            2
        """
        XCTAssertEqual(PmsetSleepGuard.parseLowPowerMode(custom2671), false, "read the AC section's High Power instead of the battery value")
    }

    /// The log says why Low Power Mode could not be read: no line, High
    /// Power, or a value that is not 0 or 1.
    func testUnreadableLowPowerModeReasonNamesTheLine() {
        XCTAssertEqual(PmsetSleepGuard.lowPowerModeUnreadable("AC Power:\n lowpowermode 1\n"), "no lowpowermode or powermode line under Battery Power")
        XCTAssertEqual(PmsetSleepGuard.lowPowerModeUnreadable("Battery Power:\n powermode 2\n"), "powermode 2 under Battery Power is High Power, not Low Power Mode on or off")
        XCTAssertEqual(PmsetSleepGuard.lowPowerModeUnreadable("Battery Power:\n powermode 3\n"), "powermode under Battery Power has value 3, not 0 or 1")
        XCTAssertEqual(PmsetSleepGuard.lowPowerModeUnreadable("Battery Power:\n lowpowermode 2\n powermode 2\n"), "lowpowermode under Battery Power has value 2, not 0 or 1")
        XCTAssertEqual(PmsetSleepGuard.lowPowerModeUnreadable("Battery Power:\n lowpowermode\n powermode 0\n"), "lowpowermode under Battery Power has no value, not 0 or 1")
    }

    /// `isLowPowerModeOn` throws with that reason, and SessionManager logs
    /// the error's description.
    func testLowPowerModeReadErrorCarriesTheReason() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-pmset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let pmset = dir.appendingPathComponent("pmset")
        try TestScripts.write("#!/bin/sh\nprintf 'Battery Power:\\n powermode 2\\nAC Power:\\n powermode 0\\n'\n", to: pmset)
        let sleepGuard = PmsetSleepGuard(sudo: "/usr/bin/false", pmset: pmset.path, timeout: 5, stopGrace: 1)
        do {
            let on = try await sleepGuard.isLowPowerModeOn()
            XCTFail("High Power read as \(on)")
        } catch let error as SleepGuardError {
            XCTAssertEqual(error.errorDescription, "`pmset -g custom` failed with status 0: powermode 2 under Battery Power is High Power, not Low Power Mode on or off")
        }
    }
}
