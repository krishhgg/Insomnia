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
}
