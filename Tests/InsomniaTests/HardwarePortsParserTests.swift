import XCTest
@testable import Insomnia

final class HardwarePortsParserTests: XCTestCase {
    let sample = """

    Hardware Port: Ethernet Adapter (en4)
    Device: en4
    Ethernet Address: 00:e0:4c:68:0a:1b

    Hardware Port: Thunderbolt Bridge
    Device: bridge0
    Ethernet Address: 36:6e:aa:bb:cc:dd

    Hardware Port: Wi-Fi
    Device: en0
    Ethernet Address: a4:83:e7:11:22:33

    VLAN Configurations
    ===================
    """

    func testFindsWifiDevice() {
        XCTAssertEqual(HardwarePortsParser.wifiInterface(from: sample), "en0")
    }

    func testLegacyAirPortName() {
        XCTAssertEqual(HardwarePortsParser.wifiInterface(from: "Hardware Port: AirPort\nDevice: en1\n"), "en1")
    }

    func testNoWifiPort() {
        XCTAssertNil(HardwarePortsParser.wifiInterface(from: "Hardware Port: Ethernet\nDevice: en5\n"))
        XCTAssertNil(HardwarePortsParser.wifiInterface(from: ""))
    }

    func testSSIDParsing() {
        XCTAssertEqual(HardwarePortsParser.ssid(fromGetAirportNetwork: "Current Wi-Fi Network: Home Net 5G\n"), "Home Net 5G")
        XCTAssertNil(HardwarePortsParser.ssid(fromGetAirportNetwork: "You are not associated with an AirPort network.\n"))
        XCTAssertNil(HardwarePortsParser.ssid(fromGetAirportNetwork: ""))
    }
}
