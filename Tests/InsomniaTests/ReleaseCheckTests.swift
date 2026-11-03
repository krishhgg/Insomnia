import Foundation
import XCTest
@testable import Insomnia

/// Stands in for GitHub's two endpoints: what `releases/latest` and the
/// first page of `releases` answer, and how many requests were made.
private actor FakeReleases: ReleaseFetching {
    private let latest: Result<Data?, ReleaseCheckError>
    private let list: Result<Data, ReleaseCheckError>
    private let gate: AsyncGate?
    private(set) var requests = 0

    init(latest: Result<Data?, ReleaseCheckError>, list: Result<Data, ReleaseCheckError>, gate: AsyncGate? = nil) {
        self.latest = latest
        self.list = list
        self.gate = gate
    }

    func latestRelease() async throws -> Data? {
        requests += 1
        return try latest.get()
    }

    func releases() async throws -> Data {
        requests += 1
        if let gate { await gate.wait() }
        return try list.get()
    }
}

/// The version line and the update check, without a window and without a
/// network: the fetcher is a fake, and the report is a pure function of
/// the installed version and GitHub's two answers.
final class ReleaseCheckTests: XCTestCase {
    private var home: TempHome!

    override func setUp() {
        super.setUp()
        home = TempHome()
    }

    override func tearDown() {
        home.destroy()
        home = nil
        super.tearDown()
    }

    // MARK: The installed version

    func testVersionAndBuildComeFromInfoPlist() {
        let build = AppBuild(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"])
        XCTAssertEqual(build, AppBuild(version: "0.1.0", build: "1"))
        XCTAssertEqual(build.label, "0.1.0 (1)")
    }

    func testABinaryWithoutAnInfoPlistSaysSo() {
        let build = AppBuild(info: [:])
        XCTAssertNil(build.version)
        XCTAssertEqual(build.label, "no version: this build has no Info.plist")
        XCTAssertEqual(AppBuild(info: ["CFBundleShortVersionString": "", "CFBundleVersion": 7]).label, "no version: this build has no Info.plist",
                       "an empty version and a build of the wrong type read as missing")
        XCTAssertEqual(AppBuild(info: ["CFBundleShortVersionString": "0.2.0"]).label, "0.2.0")
    }

    // MARK: Tags

    func testStableAndNightlyTagsParseAndOthersDoNot() {
        XCTAssertEqual(ReleaseTag("v0.1.0"), .stable(SemanticVersion(0, 1, 0)))
        XCTAssertEqual(ReleaseTag("v1.10.2"), .stable(SemanticVersion(1, 10, 2)))
        XCTAssertEqual(ReleaseTag("nightly-20261012-db9085ea12a8"), .nightly(date: "20261012", commit: "db9085ea12a8"))
        for name in ["0.1.0", "v0.1", "v0.1.0.1", "v0.1.0-rc1", "V0.1.0", "v0.1.a", "v١.0.0",
                     "nightly-2026101-db9085ea12a8", "nightly-20261012-DB9085EA12A8", "nightly-20261012-db9085ea12a",
                     "nightly-20261012-db9085ea12a8-2", "stable-0.1.0", ""] {
            XCTAssertNil(ReleaseTag(name), name)
        }
    }

    func testVersionsCompareNumericallyNotAsText() {
        XCTAssertLessThan(SemanticVersion("0.9.9")!, SemanticVersion("0.10.0")!)
        XCTAssertLessThan(SemanticVersion("1.2.3")!, SemanticVersion("1.2.10")!)
        XCTAssertLessThan(SemanticVersion("1.9.9")!, SemanticVersion("2.0.0")!)
        XCTAssertEqual(SemanticVersion("0.1.0"), SemanticVersion(0, 1, 0))
        XCTAssertEqual("\(SemanticVersion(1, 10, 2))", "1.10.2")
    }

    // MARK: The report

    private let installed = AppBuild(version: "0.1.0", build: "1")

    private func release(_ tag: String, prerelease: Bool, draft: Bool = false, published: String? = nil) -> GitHubRelease {
        GitHubRelease(tagName: tag, prerelease: prerelease, draft: draft, publishedAt: published)
    }

    /// Thirty nightlies fill the list's first page, so the stable release
    /// is on no page the check reads. It comes from `releases/latest`.
    func testANewerStableReleaseIsReportedEvenWhenNightliesFillTheList() {
        let nightlies = (1...30).map { day in
            release(String(format: "nightly-202611%02d-%012x", day, day), prerelease: true, published: String(format: "2026-11-%02dT17:00:00Z", day))
        }
        let report = ReleaseReport(installed: installed, latest: release("v0.2.0", prerelease: false), releases: nightlies)

        XCTAssertEqual(report.standing, .newerStableAvailable)
        XCTAssertEqual(report.newestStable, SemanticVersion(0, 2, 0))
        XCTAssertEqual(report.newestNightly, "nightly-20261130-00000000001e")
        XCTAssertEqual(report.summary, "A newer stable release exists: 0.2.0. You have 0.1.0. Newest nightly: nightly-20261130-00000000001e.")
        XCTAssertEqual(report.logLine, "installed 0.1.0 (1), newest stable 0.2.0, newest nightly nightly-20261130-00000000001e: newer stable release available")
    }

    /// The stable release is the one GitHub marks Latest, as
    /// docs/install.md defines the channel, not the highest tag on the
    /// list: the maintainer can mark an older line's patch release Latest.
    func testTheStableReleaseIsWhatGitHubMarksLatestNotTheHighestTag() {
        let report = ReleaseReport(installed: installed, latest: release("v0.1.1", prerelease: false), releases: [
            release("v0.2.0", prerelease: false),
            release("v0.1.1", prerelease: false),
        ])

        XCTAssertEqual(report.newestStable, SemanticVersion(0, 1, 1))
        XCTAssertEqual(report.standing, .newerStableAvailable)
    }

    func testTheInstalledVersionCanBeTheNewestStable() {
        let report = ReleaseReport(installed: installed, latest: release("v0.1.0", prerelease: false), releases: [
            release("nightly-20261011-2c116dd6399c", prerelease: true),
            release("v0.1.0", prerelease: false),
        ])

        XCTAssertEqual(report.standing, .upToDate)
        XCTAssertEqual(report.summary, "You have the newest stable release, 0.1.0. Newest nightly: nightly-20261011-2c116dd6399c.")
    }

    /// A nightly reports the version Info.plist has on main, which is above
    /// the stable one once main bumps it. That is not an update, and the
    /// report does not guess where the build came from: the same line is
    /// shown to someone on stable 0.2.0 after 0.1.1 was marked Latest.
    func testAVersionAboveTheReleaseMarkedLatestIsNotBehind() {
        let nightlyOfABumpedMain = ReleaseReport(installed: AppBuild(version: "0.2.0", build: "1"), latest: release("v0.1.0", prerelease: false), releases: [
            release("v0.1.0", prerelease: false),
        ])
        let stableAboveAnOlderLatest = ReleaseReport(installed: AppBuild(version: "0.2.0", build: "1"), latest: release("v0.1.1", prerelease: false), releases: [
            release("v0.1.1", prerelease: false),
            release("v0.2.0", prerelease: false),
        ])

        XCTAssertEqual(nightlyOfABumpedMain.standing, .aheadOfStable)
        XCTAssertEqual(nightlyOfABumpedMain.summary, "You have 0.2.0, higher than the release marked Latest, 0.1.0. No nightly is published.")
        XCTAssertEqual(stableAboveAnOlderLatest.standing, .aheadOfStable)
        XCTAssertEqual(stableAboveAnOlderLatest.summary, "You have 0.2.0, higher than the release marked Latest, 0.1.1. No nightly is published.")
        XCTAssertFalse(stableAboveAnOlderLatest.summary.contains("nightly or a source build"))
        XCTAssertEqual(stableAboveAnOlderLatest.logLine, "installed 0.2.0 (1), newest stable 0.1.1, newest nightly none: higher than the release marked Latest")
    }

    func testALatestThatIsNotAStableReleaseCountsAsNone() {
        for latest in [
            release("v0.3.0", prerelease: false, draft: true),
            release("v0.2.0", prerelease: true),
            release("0.4.0", prerelease: false),
            release("nightly-20261012-db9085ea12a8", prerelease: true),
        ] {
            let report = ReleaseReport(installed: installed, latest: latest, releases: [])
            XCTAssertNil(report.newestStable, latest.tagName)
            XCTAssertEqual(report.standing, .noStableRelease, latest.tagName)
        }
    }

    func testOnlyPrereleasesWithNightlyTagsAreNightlies() {
        let report = ReleaseReport(installed: installed, latest: nil, releases: [
            release("nightly-20261013-0123456789ab", prerelease: true, draft: true),
            release("nightly-20261012-db9085ea12a8", prerelease: false),
            release("v0.2.0", prerelease: true),
            release("nightly-20261011-2c116dd6399c", prerelease: true),
        ])

        XCTAssertEqual(report.newestNightly, "nightly-20261011-2c116dd6399c", "a draft, a nightly tag not marked prerelease, and a prerelease with a stable tag are passed over")
    }

    func testTheNewestNightlyIsTheLatestDateThenTheLatestPublishedTime() {
        let report = ReleaseReport(installed: installed, latest: nil, releases: [
            release("nightly-20261011-2c116dd6399c", prerelease: true, published: "2026-10-11T14:16:27Z"),
            release("nightly-20261012-0123456789ab", prerelease: true, published: "2026-10-12T09:00:00Z"),
            release("nightly-20261012-db9085ea12a8", prerelease: true, published: "2026-10-12T17:00:11Z"),
        ])

        XCTAssertEqual(report.newestNightly, "nightly-20261012-db9085ea12a8")
    }

    func testNoStableReleaseYet() {
        let report = ReleaseReport(installed: installed, latest: nil, releases: [
            release("nightly-20261012-db9085ea12a8", prerelease: true),
        ])

        XCTAssertEqual(report.standing, .noStableRelease)
        XCTAssertEqual(report.summary, "No stable release is published yet. Newest nightly: nightly-20261012-db9085ea12a8.")
        XCTAssertEqual(ReleaseReport(installed: installed, latest: nil, releases: []).summary, "No stable release is published yet. No nightly is published.")
    }

    func testABuildWithoutAVersionStillLearnsTheNewestTags() {
        let unpackaged = ReleaseReport(installed: AppBuild(version: nil, build: nil), latest: release("v0.1.0", prerelease: false), releases: [])
        let odd = ReleaseReport(installed: AppBuild(version: "0.1", build: "1"), latest: release("v0.1.0", prerelease: false), releases: [])

        XCTAssertEqual(unpackaged.standing, .installedVersionUnknown)
        XCTAssertEqual(unpackaged.summary, "This build has no version to compare. The newest stable release is 0.1.0. No nightly is published.")
        XCTAssertEqual(odd.standing, .installedVersionUnknown, "a version that is not major.minor.patch cannot be compared")
    }

    // MARK: The answers from GitHub

    func testTheReleasesListDecodesFromGitHubsFields() throws {
        let json = """
        [
          {"tag_name": "nightly-20261012-db9085ea12a8", "name": "Insomnia nightly 2026-10-12 (db9085ea12a8)", "draft": false, "prerelease": true, "published_at": "2026-10-12T17:00:11Z", "html_url": "https://github.com/krishhgg/Insomnia/releases/tag/nightly-20261012-db9085ea12a8", "assets": []},
          {"tag_name": "v0.1.0", "name": "Insomnia 0.1.0 (stable)", "draft": false, "prerelease": false, "published_at": "2026-10-10T17:42:47Z", "html_url": "https://github.com/krishhgg/Insomnia/releases/tag/v0.1.0", "assets": []}
        ]
        """

        let releases = try ReleaseChecker.decode(Data(json.utf8))

        XCTAssertEqual(releases, [
            GitHubRelease(tagName: "nightly-20261012-db9085ea12a8", prerelease: true, publishedAt: "2026-10-12T17:00:11Z"),
            GitHubRelease(tagName: "v0.1.0", prerelease: false, publishedAt: "2026-10-10T17:42:47Z"),
        ])
    }

    func testTheLatestReleaseDecodesAndAMissingOneStaysMissing() throws {
        let json = """
        {"tag_name": "v0.1.0", "name": "Insomnia 0.1.0 (stable)", "draft": false, "prerelease": false, "published_at": "2026-10-10T17:42:47Z", "html_url": "https://github.com/krishhgg/Insomnia/releases/tag/v0.1.0", "assets": []}
        """

        XCTAssertEqual(try ReleaseChecker.decodeLatest(Data(json.utf8)), GitHubRelease(tagName: "v0.1.0", prerelease: false, publishedAt: "2026-10-10T17:42:47Z"))
        XCTAssertNil(try ReleaseChecker.decodeLatest(nil))
    }

    func testAnAnswerThatIsNotWhatWasAskedIsOneError() {
        for body in ["{\"message\": \"API rate limit exceeded\"}", "<html>", "", "[{\"tag_name\": 1}]"] {
            XCTAssertThrowsError(try ReleaseChecker.decode(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? ReleaseCheckError, .unexpectedAnswer)
            }
        }
        for body in ["{\"message\": \"Not Found\"}", "<html>", "", "[]"] {
            XCTAssertThrowsError(try ReleaseChecker.decodeLatest(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? ReleaseCheckError, .unexpectedAnswer)
            }
        }
    }

    func testTheRequestsAreUnauthenticatedGetsOfTheTwoEndpoints() {
        XCTAssertEqual(GitHubReleaseFetcher.latestEndpoint.absoluteString, "https://api.github.com/repos/krishhgg/Insomnia/releases/latest")
        XCTAssertEqual(GitHubReleaseFetcher.listEndpoint.absoluteString, "https://api.github.com/repos/krishhgg/Insomnia/releases?per_page=30")
        XCTAssertEqual(GitHubReleaseFetcher.releasesPage.absoluteString, "https://github.com/krishhgg/Insomnia/releases")

        for url in [GitHubReleaseFetcher.latestEndpoint, GitHubReleaseFetcher.listEndpoint] {
            let request = GitHubReleaseFetcher.request(url, installed: installed)
            XCTAssertEqual(request.url, url)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Insomnia/0.1.0")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            XCTAssertEqual(request.timeoutInterval, 15)
        }
        XCTAssertEqual(GitHubReleaseFetcher.request(GitHubReleaseFetcher.listEndpoint, installed: AppBuild(version: nil, build: nil)).value(forHTTPHeaderField: "User-Agent"), "Insomnia/unpackaged")
    }

    // MARK: The transport

    /// The session refuses a redirect. The stub plays GitHub answering
    /// `302` to another host, and that host answering `200` with a valid
    /// list, so a session that followed the redirect would succeed. The
    /// fetcher instead fails with the 302, and the other host sees no
    /// request.
    func testARedirectIsNotFollowedAndIsReportedAsItsStatus() async {
        RedirectStub.script.reset(mode: .redirect)
        let fetcher = GitHubReleaseFetcher(configuration: RedirectStub.configuration)

        for call in ["releases", "latestRelease"] {
            do {
                if call == "releases" { _ = try await fetcher.releases() } else { _ = try await fetcher.latestRelease() }
                XCTFail("\(call) followed the redirect and accepted the other host's answer")
            } catch {
                XCTAssertEqual(error as? ReleaseCheckError, .status(302), call)
            }
        }
        XCTAssertEqual(RedirectStub.script.requests, [GitHubReleaseFetcher.listEndpoint, GitHubReleaseFetcher.latestEndpoint], "one request each, none to the redirect's host")
    }

    /// The same session, with GitHub answering directly: the list comes
    /// back as sent, and a 404 for the latest release is nil, not an error.
    func testDirectAnswersComeBackAsSent() async throws {
        RedirectStub.script.reset(mode: .direct)
        let fetcher = GitHubReleaseFetcher(configuration: RedirectStub.configuration)

        let list = try await fetcher.releases()
        let latest = try await fetcher.latestRelease()

        XCTAssertEqual(list, RedirectStub.listBody)
        XCTAssertNil(latest)
        XCTAssertEqual(RedirectStub.script.requests, [GitHubReleaseFetcher.listEndpoint, GitHubReleaseFetcher.latestEndpoint])
    }

    // MARK: The button

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func stable(_ tag: String) throws -> Data {
        try json(["tag_name": tag, "draft": false, "prerelease": false, "published_at": "2026-10-20T10:00:00Z"])
    }

    @MainActor
    func testAClickReportsTheNewestReleasesAndLogsThem() async throws {
        let list = try json([
            ["tag_name": "nightly-20261021-0123456789ab", "draft": false, "prerelease": true, "published_at": "2026-10-21T17:00:00Z"],
            ["tag_name": "v0.2.0", "draft": false, "prerelease": false, "published_at": "2026-10-20T10:00:00Z"],
        ])
        let latest = try stable("v0.2.0")
        let fake = FakeReleases(latest: .success(latest), list: .success(list))
        let checker = ReleaseChecker(fetcher: fake, installed: installed)
        XCTAssertEqual(checker.state, .idle)

        checker.check()
        XCTAssertEqual(checker.state, .checking)
        await checker.finish()

        XCTAssertEqual(checker.state, .checked(ReleaseReport(installed: installed, newestStable: SemanticVersion(0, 2, 0), newestNightly: "nightly-20261021-0123456789ab")))
        let requests = await fake.requests
        XCTAssertEqual(requests, 2)
        let log = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("[info] insomnia: release check: asking GitHub for the latest release and the releases list"), log)
        XCTAssertTrue(log.contains("[info] insomnia: release check: installed 0.1.0 (1), newest stable 0.2.0, newest nightly nightly-20261021-0123456789ab: newer stable release available"), log)
    }

    /// GitHub answers 404 for `releases/latest` while only nightlies are
    /// published. That is an answer, not a failure.
    @MainActor
    func testNoLatestReleaseIsReportedNotFailed() async throws {
        let list = try json([["tag_name": "nightly-20261021-0123456789ab", "draft": false, "prerelease": true]])
        let checker = ReleaseChecker(fetcher: FakeReleases(latest: .success(nil), list: .success(list)), installed: installed)

        checker.check()
        await checker.finish()

        XCTAssertEqual(checker.state, .checked(ReleaseReport(installed: installed, newestStable: nil, newestNightly: "nightly-20261021-0123456789ab")))
    }

    @MainActor
    func testAFailedRequestShowsItsReasonAndLogsIt() async throws {
        let latest = try stable("v0.1.0")
        let checker = ReleaseChecker(fetcher: FakeReleases(latest: .success(latest), list: .failure(.status(403))), installed: installed)

        checker.check()
        await checker.finish()

        XCTAssertEqual(checker.state, .failed("GitHub answered HTTP 403"))
        let log = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("[error] insomnia: release check failed: GitHub answered HTTP 403"), log)
    }

    @MainActor
    func testAnAnswerThatIsNotAListFailsTheCheck() async throws {
        let rateLimited = Data("{\"message\":\"API rate limit exceeded\"}".utf8)
        let checker = ReleaseChecker(fetcher: FakeReleases(latest: .success(rateLimited), list: .success(rateLimited)), installed: installed)

        checker.check()
        await checker.finish()

        XCTAssertEqual(checker.state, .failed("GitHub's answer was not a releases list"))
    }

    /// A second click while the requests are in flight makes no further
    /// request (two per check, not four); a click after the answer does.
    @MainActor
    func testAClickDuringACheckMakesNoFurtherRequest() async throws {
        let gate = AsyncGate()
        let list = try json([["tag_name": "v0.1.0", "draft": false, "prerelease": false]])
        let latest = try stable("v0.1.0")
        let fake = FakeReleases(latest: .success(latest), list: .success(list), gate: gate)
        let checker = ReleaseChecker(fetcher: fake, installed: installed)

        checker.check()
        await gate.waitUntilStarted()
        checker.check()
        XCTAssertEqual(checker.state, .checking)

        await gate.open()
        await checker.finish()
        XCTAssertEqual(checker.state, .checked(ReleaseReport(installed: installed, newestStable: SemanticVersion(0, 1, 0), newestNightly: nil)))
        var requests = await fake.requests
        XCTAssertEqual(requests, 2)

        checker.check()
        await checker.finish()
        requests = await fake.requests
        XCTAssertEqual(requests, 4)
    }
}


/// Plays GitHub for one `URLSession`: in `.redirect` mode every request to
/// api.github.com gets a 302 to `elsewhere`, and a request that reaches
/// `elsewhere` gets a 200 with a valid list; in `.direct` mode the list
/// endpoint gets `listBody` and the latest endpoint a 404. Every request
/// is recorded in the order received.
private final class RedirectStub: URLProtocol {
    enum Mode { case redirect, direct }

    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var _mode: Mode = .direct
        private var _requests: [URL] = []

        var mode: Mode { lock.withLock { _mode } }
        var requests: [URL] { lock.withLock { _requests } }

        func reset(mode: Mode) {
            lock.withLock {
                _mode = mode
                _requests = []
            }
        }

        func record(_ url: URL) { lock.withLock { _requests.append(url) } }
    }

    static let script = Script()
    static let elsewhere = URL(string: "https://elsewhere.test/releases")!
    static let listBody = Data("[{\"tag_name\": \"v0.1.0\", \"draft\": false, \"prerelease\": false}]".utf8)
    static let elsewhereBody = Data("[{\"tag_name\": \"v9.9.9\", \"draft\": false, \"prerelease\": false}]".utf8)

    static let configuration: @Sendable () -> URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStub.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.script.record(url)
        if url.host == "api.github.com", Self.script.mode == .redirect {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": Self.elsewhere.absoluteString])!
            var next = request
            next.url = Self.elsewhere
            // The session asks its delegate about the redirect. A session
            // that follows it starts a new load for `next`; one that
            // refuses it finishes with the response delivered below.
            client.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data())
            client.urlProtocolDidFinishLoading(self)
            return
        }
        let body: Data
        let status: Int
        if url.host != "api.github.com" {
            body = Self.elsewhereBody
            status = 200
        } else if url == GitHubReleaseFetcher.latestEndpoint {
            body = Data("{\"message\": \"Not Found\"}".utf8)
            status = 404
        } else {
            body = Self.listBody
            status = 200
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
