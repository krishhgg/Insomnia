import Foundation

/// Keeps the launchd agent that runs backstop.sh loaded. The agent is
/// persistent: it runs at load and every minute, and enforces the deadline
/// written in session.json itself, so the app never has to replace the job
/// per extension (which used to leave a window with no agent at all).
protocol BackstopScheduling: Sendable {
    /// Make sure the polling agent is loaded with the current plist. Cheap
    /// when it already is; throws when it cannot be loaded.
    func arm() async throws
    /// Throws unless the backstop.sh the agent runs deletes the
    /// pending-start marker under its lock (see BackstopVersion). Start
    /// checks this before it shows the password dialog.
    func checkVoidsPrompts() throws
}

struct BackstopError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct LaunchdBackstop: BackstopScheduling {
    typealias Runner = @Sendable (_ exe: String, _ args: [String]) async throws -> ShellResult

    static let launchctl = "/bin/launchctl"
    /// Seconds between backstop.sh runs while loaded. install.sh writes the same value.
    static let pollInterval = 60
    static let commandTimeout: TimeInterval = 15

    let plistURL: URL
    let scriptPath: String
    let label: String
    let uid: uid_t
    private let run: Runner

    init(
        paths: Paths,
        label: String = Paths.backstopLabel,
        uid: uid_t = getuid(),
        run: @escaping Runner = { try await CancellableCommand().run($0, $1, timeout: LaunchdBackstop.commandTimeout) }
    ) {
        self.plistURL = paths.backstopPlist
        self.scriptPath = paths.backstopScript.path
        self.label = label
        self.uid = uid
        self.run = run
    }

    func arm() async throws {
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw BackstopError(message: "backstop.sh not installed at \(scriptPath); run scripts/install.sh")
        }
        let desired = Self.plistDictionary(label: label, scriptPath: scriptPath)
        if plistOnDiskMatches(desired), try await isLoaded() {
            return
        }
        // The plist at `plistURL` is what the next arm() trusts when
        // `launchctl print` says the label is loaded, so it may only ever
        // hold a plist launchd actually loaded. Load through a private
        // candidate and publish it with one rename after bootstrap succeeded.
        // A failed replacement (bootout left the old job loaded, bootstrap
        // refused, volume stopped taking writes) then leaves the trusted path
        // exactly as it was, whether or not any cleanup below works.
        let candidate = try writeCandidate(desired)
        defer { discard(candidate) }
        try await reload(from: candidate)
        try publish(candidate)
    }

    // MARK: Plist

    /// Pure builder, testable without launchd.
    static func plistDictionary(label: String, scriptPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": ["/bin/bash", scriptPath],
            "RunAtLoad": true,
            "StartInterval": pollInterval,
        ]
    }

    func plistOnDiskMatches(_ desired: [String: Any]) -> Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return NSDictionary(dictionary: obj).isEqual(to: desired)
    }

    /// Candidates are `*.plist` files in a private subdirectory of the
    /// LaunchAgents directory. launchctl refuses to bootstrap (or boot out)
    /// any path without a `.plist` suffix with EIO, so the name must end in
    /// `.plist`; launchd's login-time load of the LaunchAgents directory does
    /// not descend into subdirectories, so a candidate left behind by a
    /// crash or an unwritable volume can never be picked up as a second copy
    /// of the label; and one level below the trusted plist is still the same
    /// filesystem, so publishing stays a single rename.
    private var stagingDirectory: URL {
        plistURL.deletingLastPathComponent().appendingPathComponent(".\(label).staging", isDirectory: true)
    }
    private var candidatePrefix: String { "\(label).candidate-" }

    private func writeCandidate(_ desired: [String: Any]) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: desired, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        sweepCandidates()
        let url = stagingDirectory.appendingPathComponent(candidatePrefix + UUID().uuidString + ".plist")
        try data.write(to: url)
        return url
    }

    /// Atomically replaces the trusted plist with the candidate launchd just
    /// loaded. Throws when that fails: the agent is running for this login
    /// session, but the plist launchd reads at the next login is still the
    /// old one, so the caller must not treat the backstop as configured.
    private func publish(_ candidate: URL) throws {
        guard rename(candidate.path, plistURL.path) == 0 else {
            let reason = String(cString: strerror(errno))
            throw BackstopError(message: "backstop agent loaded but its plist could not be published to \(plistURL.path): \(reason)")
        }
    }

    /// Best effort; after a successful publish the candidate is already gone
    /// and only the (then empty) staging directory is left to remove.
    private func discard(_ candidate: URL) {
        if FileManager.default.fileExists(atPath: candidate.path) {
            do {
                try FileManager.default.removeItem(at: candidate)
            } catch {
                // Harmless to launchd (see stagingDirectory); swept by the next arm().
                Log.error("could not remove backstop candidate plist \(candidate.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // Fails while a candidate is still inside; that is fine.
        _ = rmdir(stagingDirectory.path)
    }

    private func sweepCandidates() {
        let fm = FileManager.default
        // The LaunchAgents directory itself too: an older build staged its
        // candidates there, and a leftover makes launchd's directory load
        // report an error at every login.
        for dir in [stagingDirectory, plistURL.deletingLastPathComponent()] {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(candidatePrefix) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    // MARK: launchctl

    func isLoaded() async throws -> Bool {
        let r = try await run(Self.launchctl, ["print", "gui/\(uid)/\(label)"])
        return r.succeeded
    }

    /// bootout by service target (ignored if not loaded: the trusted path may
    /// not exist yet, and a path launchctl cannot read fails with EIO rather
    /// than unloading anything), then bootstrap from the candidate. RunAtLoad
    /// means the script runs immediately; it is a no-op while the session on
    /// disk is valid and the journal is clean.
    ///
    /// Throws when the agent cannot be loaded: a session must never hold
    /// sleep without an agent that will release it.
    private func reload(from candidate: URL) async throws {
        let domain = "gui/\(uid)"
        _ = try await run(Self.launchctl, ["bootout", "\(domain)/\(label)"])
        let r = try await run(Self.launchctl, ["bootstrap", domain, candidate.path])
        if !r.succeeded {
            throw BackstopError(message: "launchctl bootstrap failed (\(r.status)): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
