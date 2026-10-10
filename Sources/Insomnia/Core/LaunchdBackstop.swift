import Foundation

/// Keeps the launchd agent that runs backstop.sh loaded. The agent is
/// persistent: it runs at load and every minute, and enforces the deadline
/// written in session.json itself, so the app never has to replace the job
/// per extension (which used to leave a window with no agent at all).
///
/// The script it runs is the backstop.sh sealed inside the app bundle
/// (Contents/Resources). The agent's command line verifies the bundle's code
/// signature against the requirement pinned in the plist and only then
/// execs the script, so a backstop.sh edited on disk is never run by
/// launchd. Nothing executable lives in a writable support directory.
///
/// What the app pins is the requirement of the code it is itself running
/// (CodeRequirement.pin), after checking that the bundle on disk still is
/// that code and still passes the agent's check. A bundle edited or
/// re-signed under the running app makes arm() fail, with the reason, rather
/// than report an agent that refuses every run or pin the replacement.
///
/// Every Insomnia folder of the user loads its agent under the one label,
/// so launchd holds one such job, from whichever folder loaded it last.
/// Every load and unload of the label happens under one lock, the standard
/// folder's recovery lock (`agentLock`): install.sh holds it as fd 9 and
/// uninstall.sh as fd 6 around each launchctl call, and arm() holds it from
/// the reading before a reload until the plist is published. So an
/// uninstall of one folder that has just read whose job is loaded unloads
/// that job, never one another folder loaded since. The lock order is the
/// folder's own recovery lock, then this one, then the receipt
/// (SleepOffReceipts); arm() runs inside a transaction and never holds the
/// receipt.
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

/// The bundle whose sealed backstop.sh the agent runs, and the code
/// requirement that bundle must satisfy first.
struct BackstopTarget: Sendable, Equatable {
    let bundle: URL
    /// Designated requirement of the bundle's signature, in requirement
    /// language, as `codesign -d -r-` prints it (see CodeRequirement).
    let requirement: String

    var script: URL { Paths.backstopScript(inBundle: bundle) }
}

struct LaunchdBackstop: BackstopScheduling {
    /// Runs one launchctl call. `holding`, when there is one, is the agent
    /// lock, handed to the child (`CancellableCommand.run(holding:)`) so a
    /// bootout or bootstrap keeps it until it exits, even if this process
    /// does not.
    typealias Runner = @Sendable (_ exe: String, _ args: [String], _ holding: RecoveryLockHandle?) async throws -> ShellResult
    /// Returns the requirement to pin for a bundle that satisfies it right
    /// now, or throws with the reason it must not be pinned.
    typealias BundlePinner = @Sendable (_ bundle: URL) throws -> String

    static let launchctl = "/bin/launchctl"
    /// Seconds between backstop.sh runs while loaded. install.sh writes the same value.
    static let pollInterval = 60
    static let commandTimeout: TimeInterval = 15
    /// How long arm() waits for the agent lock before it fails.
    static let agentLockTimeout: TimeInterval = 10

    /// What launchd runs: `/bin/sh -c <agentProgram> sh <requirement> <bundle>`.
    /// The program verifies the bundle ($2) against the requirement ($1) with
    /// codesign and execs the sealed backstop.sh only when that passes; the
    /// resource seal covers the script, so an edited copy fails here. On
    /// failure it appends one line to ~/Library/Logs/Insomnia/insomnia.log
    /// (the LaunchAgent only ever exists in the standard layout) and exits 1
    /// without running anything. install.sh embeds this same text (its
    /// AGENT_PROGRAM line); LaunchdBackstopTests checks the two are equal so
    /// the app recognises the plist install.sh wrote. No single quotes, so
    /// the shell can hold it in one.
    static let agentProgram = #"r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2>&1)" && exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Insomnia"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" >> "$HOME/Library/Logs/Insomnia/insomnia.log"; exit 1"#

    let plistURL: URL
    let bundle: URL
    let label: String
    let uid: uid_t
    /// The lock every load and unload of `label` takes (see
    /// BackstopScheduling): `Paths.standard.recoveryLock` for the app.
    let agentLock: URL
    let agentLockTimeout: TimeInterval
    private let pin: BundlePinner
    private let run: Runner

    /// `bundle` defaults to the bundle this process runs from, and, when it
    /// is not running from one (`swift run`), to the installed bundle at
    /// `paths.appBundle`, so a development build arms the agent against the
    /// installed app's sealed script. `pin` runs at every arm(), so an
    /// upgrade is pinned the first time the upgraded app arms; the default
    /// is CodeRequirement.pin (the running code's own requirement, and the
    /// agent's check on the bundle). `agentLock` has no default, so no
    /// test can reach the standard folder's lock by leaving it out.
    init(
        paths: Paths,
        agentLock: URL,
        agentLockTimeout: TimeInterval = LaunchdBackstop.agentLockTimeout,
        bundle: URL? = nil,
        pin: @escaping BundlePinner = { try CodeRequirement.pin(bundle: $0) },
        label: String = Paths.backstopLabel,
        uid: uid_t = getuid(),
        run: @escaping Runner = { try await CancellableCommand().run($0, $1, timeout: LaunchdBackstop.commandTimeout, holding: $2) }
    ) {
        self.plistURL = paths.backstopPlist
        self.bundle = bundle ?? Self.runningOrInstalledBundle(paths: paths)
        self.agentLock = agentLock
        self.agentLockTimeout = agentLockTimeout
        self.pin = pin
        self.label = label
        self.uid = uid
        self.run = run
    }

    static func runningOrInstalledBundle(paths: Paths, running: URL = Bundle.main.bundleURL) -> URL {
        running.pathExtension == "app" ? running.standardizedFileURL : paths.appBundle
    }

    var scriptPath: String { Paths.backstopScript(inBundle: bundle).path }

    func arm() async throws {
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw BackstopError(message: "backstop.sh is not sealed in the app bundle at \(scriptPath); run scripts/install.sh")
        }
        // Before trusting a loaded agent: the bundle it would verify must
        // pass that verification now. A sealed script edited after signing
        // leaves the plist current and the job loaded, but the agent refuses
        // every run; that is not armed.
        let requirement: String
        do {
            requirement = try pin(bundle)
        } catch {
            throw BackstopError(message: "the recovery agent cannot pin \(bundle.path): \(error.localizedDescription). Reinstall with scripts/install.sh")
        }
        let desired = Self.plistDictionary(label: label, target: BackstopTarget(bundle: bundle, requirement: requirement))
        // Without the agent lock: reading changes nothing, and a job this
        // folder loaded stays loaded until a holder of the lock unloads it,
        // which only this folder's uninstall does (it holds this folder's
        // recovery lock, so not during this transaction) or install.sh,
        // which replaces it with the standard folder's.
        if try await isArmed(desired) { return }
        let held = try await takeAgentLock()
        defer { held.release() }
        // Again under the lock: another folder may have loaded its job, or
        // unloaded this one, since the reading above.
        if try await isArmed(desired) { return }
        // The plist at `plistURL` is what the next arm() trusts when the
        // loaded job is the one it describes, so it may only ever hold a
        // plist launchd actually loaded. Load through a private
        // candidate and publish it with one rename after bootstrap succeeded.
        // A failed replacement (bootout left the old job loaded, bootstrap
        // refused, volume stopped taking writes) then leaves the trusted path
        // exactly as it was, whether or not any cleanup below works.
        let candidate = try writeCandidate(desired)
        defer { discard(candidate) }
        try await reload(from: candidate, holding: held.handle)
        try publish(candidate)
    }

    /// Armed when the plist the next login loads is this build's and the
    /// loaded job is the one it describes, loaded from this folder: the same
    /// command line, started every `pollInterval` seconds, from this
    /// folder's plist or one of its candidates. A loaded label alone may be
    /// another build's job, pinning a bundle or requirement this one does
    /// not satisfy (install.sh can leave one loaded when it stops between
    /// its bootstrap and publishing the plist), a job loaded from a plist
    /// without the interval, which never runs again to end a session, or
    /// another folder's job running the same command line, which that
    /// folder's uninstall unloads.
    private func isArmed(_ desired: [String: Any]) async throws -> Bool {
        guard plistOnDiskMatches(desired) else { return false }
        let r = try await run(Self.launchctl, ["print", "gui/\(uid)/\(label)"], nil)
        guard r.succeeded, Self.loadedJob(fromPrint: r.stdout) == LoadedJob(plist: desired),
              let path = Self.loadedPath(fromPrint: r.stdout)
        else { return false }
        return isOwnAgentFile(path)
    }

    /// The agent lock for one reload, released by `release()` when arm()
    /// took it itself.
    private struct AgentLockHold {
        let handle: RecoveryLockHandle
        let taken: Bool
        func release() { if taken { handle.release() } }
    }

    /// The transaction's own lock when it already is the agent lock's file
    /// (the standard folder, or a folder whose lock is a link to it): a
    /// second flock of one file in this process would wait on the first.
    /// Otherwise the agent lock, within `agentLockTimeout`, made with its
    /// folder when missing as uninstall.sh's lock_standard makes it, and
    /// checked to still be the file its path names, which is what
    /// install.sh and uninstall.sh open.
    private func takeAgentLock() async throws -> AgentLockHold {
        let path = agentLock.path
        if let held = RecoveryLock.held, let file = held.file, FileIdentity(atPath: path) == file {
            return AgentLockHold(handle: held, taken: false)
        }
        let handle: RecoveryLockHandle
        do {
            if let problem = try OwnerOnly.createDirectory(agentLock.deletingLastPathComponent()) { OwnerOnly.reportOnce(problem) }
            handle = try await RecoveryLock(url: agentLock).acquire(timeout: agentLockTimeout)
        } catch {
            throw BackstopError(message: "the recovery agent was not reloaded: \(error.localizedDescription); install.sh, uninstall.sh and the standard Insomnia folder's app and backstop take that lock")
        }
        guard let file = handle.file, FileIdentity(atPath: path) == file else {
            handle.release()
            throw BackstopError(message: "the recovery agent was not reloaded: \(path) was replaced while it was locked")
        }
        return AgentLockHold(handle: handle, taken: true)
    }

    /// Whether `path`, the file launchd says the loaded job came from, is
    /// this folder's: its plist, or a candidate in its staging folder or,
    /// for older builds, beside the plist. A candidate is renamed over the
    /// plist after the load, so the file may be gone. The folder it was in
    /// is this folder's LaunchAgents folder by path, or else when it has the
    /// same name and both it and the folder above it are this folder's by
    /// device and inode: a link to the whole folder is still this folder,
    /// while a LaunchAgents folder that only leads here from another folder
    /// is that folder's, with its own journal and lock. uninstall.sh's
    /// own_agent_file reads the path the same way.
    func isOwnAgentFile(_ path: String) -> Bool {
        guard let slash = path.lastIndex(of: "/") else { return false }
        let name = path[path.index(after: slash)...]
        var dir = String(path[..<slash])
        if name == "\(label).plist" {
        } else if name.hasPrefix(candidatePrefix) {
            if let up = dir.lastIndex(of: "/"), dir[dir.index(after: up)...] == ".\(label).staging" { dir = String(dir[..<up]) }
        } else {
            return false
        }
        let mine = plistURL.deletingLastPathComponent().path
        if dir == mine { return true }
        func parent(_ p: String) -> String { p.lastIndex(of: "/").map { String(p[..<$0]) } ?? "" }
        func last(_ p: String) -> Substring { p.lastIndex(of: "/").map { p[p.index(after: $0)...] } ?? Substring(p) }
        guard last(dir) == last(mine),
              let a = FileIdentity(atPath: mine), FileIdentity(atPath: dir) == a,
              let b = FileIdentity(atPath: parent(mine)), FileIdentity(atPath: parent(dir)) == b
        else { return false }
        return true
    }

    // MARK: Plist

    /// Pure builder, testable without launchd. Must produce exactly what
    /// install.sh writes, or every arm() reloads the agent.
    static func plistDictionary(label: String, target: BackstopTarget) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", agentProgram, "sh", target.requirement, target.bundle.path],
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

    /// What `launchctl print` shows of a loaded job that makes it this
    /// build's polling agent: the command it runs and how often launchd
    /// starts it.
    struct LoadedJob: Equatable, Sendable {
        var arguments: [String]
        /// StartInterval in seconds; nil when the job has none, so launchd
        /// never starts it again by itself.
        var runInterval: Int?

        init(arguments: [String], runInterval: Int?) {
            self.arguments = arguments
            self.runInterval = runInterval
        }

        /// The job a plist from `plistDictionary` loads as.
        init(plist: [String: Any]) {
            self.init(arguments: plist["ProgramArguments"] as? [String] ?? [], runInterval: plist["StartInterval"] as? Int)
        }
    }

    /// The file the job was loaded from, from `launchctl print`: the one
    /// top-level `path =` line (one tab in, like every top-level key). nil
    /// when there is none, more than one, or it is not an absolute path,
    /// as uninstall.sh's loaded_agent reads it.
    static func loadedPath(fromPrint output: String) -> String? {
        let prefix = "\tpath = "
        let found = output.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.hasPrefix(prefix) }
        guard found.count == 1, let path = found.first?.dropFirst(prefix.count), path.hasPrefix("/") else { return nil }
        return String(path)
    }

    /// Reads `launchctl print <service>` output, whose top-level keys are
    /// indented by one tab. `arguments = {` opens a block of one argument per
    /// line, indented by two tabs, closed by `\t}`; `run interval = <n>
    /// seconds` is there only for a job with a StartInterval. nil when the
    /// arguments block is missing, repeated, unclosed or holds a line this
    /// does not know; a run interval in another form reads as none. Either
    /// way the job does not match a plist, and arm() reloads it.
    static func loadedJob(fromPrint output: String) -> LoadedJob? {
        let intervalPrefix = "\trun interval = ", intervalSuffix = " seconds"
        var arguments: [String]?
        var inArguments = false
        var runInterval: Int?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if inArguments {
                if line == "\t}" {
                    inArguments = false
                } else if line.hasPrefix("\t\t") {
                    arguments?.append(String(line.dropFirst(2)))
                } else {
                    return nil
                }
            } else if line == "\targuments = {" {
                guard arguments == nil else { return nil }
                arguments = []
                inArguments = true
            } else if line.hasPrefix(intervalPrefix), line.hasSuffix(intervalSuffix) {
                runInterval = Int(line.dropFirst(intervalPrefix.count).dropLast(intervalSuffix.count))
            }
        }
        guard let arguments, !inArguments else { return nil }
        return LoadedJob(arguments: arguments, runInterval: runInterval)
    }

    /// bootout by service target (ignored if not loaded: the trusted path may
    /// not exist yet, and a path launchctl cannot read fails with EIO rather
    /// than unloading anything), then bootstrap from the candidate. RunAtLoad
    /// means the script runs immediately; it is a no-op while the session on
    /// disk is valid and the journal is clean.
    ///
    /// Throws when the agent cannot be loaded: a session must never hold
    /// sleep without an agent that will release it.
    ///
    /// Both calls get the agent lock: the runner returns only once the
    /// child has exited and been reaped (SIGTERM, then SIGKILL, at its
    /// limit), and the child's own descriptor keeps the lock if this
    /// process ends first.
    private func reload(from candidate: URL, holding lock: RecoveryLockHandle) async throws {
        let domain = "gui/\(uid)"
        _ = try await run(Self.launchctl, ["bootout", "\(domain)/\(label)"], lock)
        let r = try await run(Self.launchctl, ["bootstrap", domain, candidate.path], lock)
        if !r.succeeded {
            throw BackstopError(message: "launchctl bootstrap failed (\(r.status)): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
