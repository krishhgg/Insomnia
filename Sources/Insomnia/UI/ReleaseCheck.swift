import Foundation
import Observation

/// The version this build carries in its Info.plist:
/// `CFBundleShortVersionString` and `CFBundleVersion`. A binary run from
/// `swift run` has no Info.plist, so it has neither.
///
/// A nightly carries the version Info.plist has on main at that commit,
/// the same string as the stable release it follows or the one it
/// precedes, so the version alone does not tell a nightly apart. The
/// nightly's tag and zip name do (docs/releasing.md).
struct AppBuild: Equatable, Sendable {
    var version: String?
    var build: String?

    static let current = AppBuild(info: Bundle.main.infoDictionary ?? [:])

    init(version: String?, build: String?) {
        self.version = version
        self.build = build
    }

    init(info: [String: Any]) {
        version = Self.nonEmpty(info["CFBundleShortVersionString"])
        build = Self.nonEmpty(info["CFBundleVersion"])
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// For Settings and the launch log: "0.1.0 (1)", or what is missing.
    var label: String {
        switch (version, build) {
        case let (version?, build?): "\(version) (\(build))"
        case let (version?, nil): version
        case (nil, _): "no version: this build has no Info.plist"
        }
    }
}

/// `major.minor.patch`, the form a stable tag `v<version>` and
/// `CFBundleShortVersionString` take. Anything else does not parse.
struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy(ReleaseTag.isDigit), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// A release tag the Release workflow makes: `v<version>` for a stable
/// release, `nightly-<UTC date>-<first 12 hex digits of the commit>` for
/// a nightly. Any other tag name is not one of Insomnia's releases.
enum ReleaseTag: Equatable, Sendable {
    case stable(SemanticVersion)
    case nightly(date: String, commit: String)

    init?(_ name: String) {
        if name.hasPrefix("v"), let version = SemanticVersion(String(name.dropFirst())) {
            self = .stable(version)
            return
        }
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "nightly",
              parts[1].count == 8, parts[1].utf8.allSatisfy(Self.isDigit),
              parts[2].count == 12, parts[2].utf8.allSatisfy(Self.isLowercaseHex)
        else { return nil }
        self = .nightly(date: String(parts[1]), commit: String(parts[2]))
    }

    static func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

    static func isLowercaseHex(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
    }
}

/// One entry of GitHub's releases list, the fields the check reads.
struct GitHubRelease: Decodable, Equatable, Sendable {
    var tagName: String
    var prerelease: Bool
    var draft: Bool
    var publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case draft
        case publishedAt = "published_at"
    }

    init(tagName: String, prerelease: Bool, draft: Bool = false, publishedAt: String? = nil) {
        self.tagName = tagName
        self.prerelease = prerelease
        self.draft = draft
        self.publishedAt = publishedAt
    }
}

/// What GitHub says next to the installed version. The newest stable
/// release is the one GitHub marks Latest (`releases/latest`: the newest
/// release that is neither a draft nor a prerelease), which the channels
/// in docs/install.md define the same way. It comes from its own endpoint
/// because the releases list is paged newest first and a nightly is
/// published on each day main has new commits, so the stable release can
/// sit behind any number of nightlies. The newest nightly is the
/// prerelease with the latest date in its tag on the list's first page,
/// where the newest entries are, and the latest `published_at` among
/// those of one day.
struct ReleaseReport: Equatable, Sendable {
    enum Standing: Equatable, Sendable {
        /// A stable release with a higher version than the installed one.
        case newerStableAvailable
        /// The installed version is the newest stable release's.
        case upToDate
        /// The installed version is above the newest stable release's: a
        /// nightly or a source build of a main that bumped the version.
        case aheadOfStable
        case noStableRelease
        /// No version in Info.plist, or one that is not `major.minor.patch`.
        case installedVersionUnknown
    }

    var installed: AppBuild
    var newestStable: SemanticVersion?
    /// The tag of the newest nightly, as it is on the releases page.
    var newestNightly: String?

    init(installed: AppBuild, newestStable: SemanticVersion?, newestNightly: String?) {
        self.installed = installed
        self.newestStable = newestStable
        self.newestNightly = newestNightly
    }

    /// `latest` is GitHub's answer for `releases/latest`, nil when it has
    /// none (HTTP 404). A Latest whose tag is not `v<version>` is not one
    /// the Release workflow made and counts as none; the log line shows
    /// "newest stable none" for it.
    init(installed: AppBuild, latest: GitHubRelease?, releases: [GitHubRelease]) {
        var stable: SemanticVersion?
        if let latest, !latest.draft, !latest.prerelease, case let .stable(version)? = ReleaseTag(latest.tagName) {
            stable = version
        }
        var nightly: (tag: String, date: String, published: String)?
        for release in releases where !release.draft && release.prerelease {
            guard case let .nightly(date, _)? = ReleaseTag(release.tagName) else { continue }
            let candidate = (tag: release.tagName, date: date, published: release.publishedAt ?? "")
            if let known = nightly, (known.date, known.published) >= (candidate.date, candidate.published) { continue }
            nightly = candidate
        }
        self.init(installed: installed, newestStable: stable, newestNightly: nightly?.tag)
    }

    var standing: Standing {
        guard let text = installed.version, let installedVersion = SemanticVersion(text) else { return .installedVersionUnknown }
        guard let newestStable else { return .noStableRelease }
        if installedVersion < newestStable { return .newerStableAvailable }
        if installedVersion == newestStable { return .upToDate }
        return .aheadOfStable
    }

    /// The line under the button in Settings.
    var summary: String {
        let stable = newestStable.map { "\($0)" }
        let first: String = switch standing {
        case .newerStableAvailable:
            "A newer stable release exists: \(stable ?? ""). You have \(installed.version ?? "")."
        case .upToDate:
            "You have the newest stable release, \(stable ?? "")."
        case .aheadOfStable:
            "You have \(installed.version ?? ""), above the newest stable release, \(stable ?? ""). That is a nightly or a source build."
        case .noStableRelease:
            "No stable release is published yet."
        case .installedVersionUnknown:
            "This build has no version to compare. The newest stable release is \(stable ?? "none")."
        }
        let second = newestNightly.map { "Newest nightly: \($0)." } ?? "No nightly is published."
        return first + " " + second
    }

    /// One line for insomnia.log: numbers, tags and a fixed phrase.
    var logLine: String {
        let outcome: String = switch standing {
        case .newerStableAvailable: "newer stable release available"
        case .upToDate: "up to date"
        case .aheadOfStable: "ahead of the newest stable release"
        case .noStableRelease: "no stable release published"
        case .installedVersionUnknown: "installed version unknown"
        }
        let stable = newestStable.map { "\($0)" } ?? "none"
        return "installed \(installed.label), newest stable \(stable), newest nightly \(newestNightly ?? "none"): \(outcome)"
    }
}

enum ReleaseCheckError: LocalizedError, Equatable {
    case notHTTP
    case status(Int)
    case unexpectedAnswer

    var errorDescription: String? {
        switch self {
        case .notHTTP: "the answer was not an HTTP response"
        case let .status(code): "GitHub answered HTTP \(code)"
        case .unexpectedAnswer: "GitHub's answer was not a releases list"
        }
    }
}

/// GitHub's two answers as its API gives them, behind a protocol so tests
/// hand in JSON and failures without a network.
protocol ReleaseFetching: Sendable {
    /// `releases/latest`, or nil when GitHub has no stable release (404).
    func latestRelease() async throws -> Data?
    /// The first page of `releases`, newest first.
    func releases() async throws -> Data
}

/// Two unauthenticated GETs of this repository's releases: the one GitHub
/// marks Latest, and the first page of the list. No token, no cache, no
/// redirects to follow: the endpoints answer directly. Each request carries
/// the installed version as its user agent and nothing else about the Mac.
struct GitHubReleaseFetcher: ReleaseFetching {
    static let releasesPage = URL(string: "https://github.com/krishhgg/Insomnia/releases")!
    static let latestEndpoint = URL(string: "https://api.github.com/repos/krishhgg/Insomnia/releases/latest")!
    static let listEndpoint = URL(string: "https://api.github.com/repos/krishhgg/Insomnia/releases?per_page=30")!
    static let timeout: TimeInterval = 15

    static func request(_ url: URL, installed: AppBuild) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Insomnia/\(installed.version ?? "unpackaged")", forHTTPHeaderField: "User-Agent")
        return request
    }

    func latestRelease() async throws -> Data? {
        try await get(Self.latestEndpoint, noneOn404: true)
    }

    func releases() async throws -> Data {
        guard let data = try await get(Self.listEndpoint, noneOn404: false) else { throw ReleaseCheckError.status(404) }
        return data
    }

    private func get(_ url: URL, noneOn404: Bool) async throws -> Data? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: Self.request(url, installed: .current))
        guard let http = response as? HTTPURLResponse else { throw ReleaseCheckError.notHTTP }
        if http.statusCode == 404, noneOn404 { return nil }
        guard http.statusCode == 200 else { throw ReleaseCheckError.status(http.statusCode) }
        return data
    }
}

/// The "Check for updates" button in Settings > App. Two requests to
/// GitHub when the user clicks (the Latest release and the first page of
/// the list), a report under the button, and nothing installed: an upgrade
/// is the installer run again (docs/install.md, Upgrades). The app never
/// checks on its own.
@MainActor
@Observable
final class ReleaseChecker {
    enum State: Equatable {
        case idle
        case checking
        case checked(ReleaseReport)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private let fetcher: any ReleaseFetching
    @ObservationIgnored private let installed: AppBuild
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    init(fetcher: any ReleaseFetching = GitHubReleaseFetcher(), installed: AppBuild = .current) {
        self.fetcher = fetcher
        self.installed = installed
    }

    /// Starts a check. A click while one is in flight does nothing.
    func check() {
        guard inFlight == nil else { return }
        state = .checking
        Log.info("release check: asking GitHub for the latest release and the releases list")
        inFlight = Task { [fetcher, installed] in
            let outcome: State
            do {
                async let latestData = fetcher.latestRelease()
                async let listData = fetcher.releases()
                let latest = try await Self.decodeLatest(latestData)
                let releases = try await Self.decode(listData)
                let report = ReleaseReport(installed: installed, latest: latest, releases: releases)
                Log.info("release check: \(report.logLine)")
                outcome = .checked(report)
            } catch {
                Log.error("release check failed: \(error.localizedDescription)")
                outcome = .failed(error.localizedDescription)
            }
            self.state = outcome
            self.inFlight = nil
        }
    }

    /// Waits for the check in flight, if any. For tests.
    func finish() async {
        await inFlight?.value
    }

    nonisolated static func decode(_ data: Data) throws -> [GitHubRelease] {
        do {
            return try JSONDecoder().decode([GitHubRelease].self, from: data)
        } catch {
            throw ReleaseCheckError.unexpectedAnswer
        }
    }

    /// nil stays nil: GitHub had no stable release.
    nonisolated static func decodeLatest(_ data: Data?) throws -> GitHubRelease? {
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw ReleaseCheckError.unexpectedAnswer
        }
    }
}
