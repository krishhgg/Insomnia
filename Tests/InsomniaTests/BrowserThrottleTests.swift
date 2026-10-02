import XCTest
@testable import Insomnia

final class BrowserThrottleTests: XCTestCase {
    let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    func testBothFlagsPresent() {
        XCTAssertTrue(ChromiumFlags.hasBothFlags(args: "\(chrome) --disable-backgrounding-occluded-windows --disable-renderer-backgrounding"))
        XCTAssertTrue(ChromiumFlags.hasBothFlags(args: "\(chrome) --disable-renderer-backgrounding --foo=bar --disable-backgrounding-occluded-windows\n"))
    }

    func testOneFlagIsNotEnough() {
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: "\(chrome) --disable-backgrounding-occluded-windows"))
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: "\(chrome) --disable-renderer-backgrounding"))
    }

    func testNoFlags() {
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: chrome))
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: ""))
    }

    func testFlagsInsideQuotedArgDoNotCount() {
        let args = "\(chrome) --user-data-dir=\"/tmp/--disable-backgrounding-occluded-windows --disable-renderer-backgrounding\""
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: args))
        let single = "\(chrome) --note='--disable-backgrounding-occluded-windows --disable-renderer-backgrounding'"
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: single))
    }

    func testFlagsNextToQuotedArgStillCount() {
        let args = "\(chrome) --user-data-dir=\"/Users/me/My Profile\" --disable-backgrounding-occluded-windows --disable-renderer-backgrounding"
        XCTAssertTrue(ChromiumFlags.hasBothFlags(args: args))
    }

    func testPrefixLookalikesDoNotCount() {
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: "\(chrome) --disable-backgrounding-occluded-windows-x --disable-renderer-backgrounding"))
    }

    func testTokenizer() {
        XCTAssertEqual(ChromiumFlags.tokenize("a  b\t'c d' \"e f\" g\\ h"), ["a", "b", "c d", "e f", "g h"])
        XCTAssertEqual(ChromiumFlags.tokenize(""), [])
    }

    func testPreservedArgs() {
        let args = "\(chrome) --user-data-dir=/tmp/p --profile-directory=\"Profile 2\" --no-first-run"
        XCTAssertEqual(ChromiumFlags.preservedArgs(args: args), ["--user-data-dir=/tmp/p", "--profile-directory=Profile 2"])
    }

    func testChromiumBundleIdsFromAgentList() {
        var c = Config()
        c.agentList = ["com.example.chromeagent", "dev.some.Chromium-Fork", "com.apple.Safari"]
        let ids = ChromiumFlags.chromiumBundleIds(config: c)
        XCTAssertTrue(ids.contains("com.google.Chrome"))
        XCTAssertTrue(ids.contains("org.chromium.Chromium"))
        XCTAssertTrue(ids.contains("company.thebrowser.Browser"))
        XCTAssertTrue(ids.contains("com.example.chromeagent"))
        XCTAssertTrue(ids.contains("dev.some.Chromium-Fork"))
        XCTAssertFalse(ids.contains("com.apple.Safari"))
    }
}
