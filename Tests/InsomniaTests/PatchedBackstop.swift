import Darwin
import Foundation
import XCTest
@testable import Insomnia

/// A copy of backstop.sh whose tools are fakes in `dir`, for tests that run
/// the real agent beside a SessionManager on the same INSOMNIA_HOME: pmset
/// reports an internal battery on battery power at 25% or the level set
/// with `setBattery`, notifyutil the thermal pressure level set with
/// `setThermal`, sudo succeeds. Each call is recorded in dir/calls, and
/// each sudo call also copies state.json as it was at that moment to
/// dir/state-at-sudo (removed when there is none) and lists the names in
/// INSOMNIA_HOME to dir/names-at-sudo and in its Logs folder to
/// dir/logs-at-sudo. The app binary is the one this build made, for
/// `--agent-cutoffs` and `--agent-session-cutoffs` only (`BuiltApp`),
/// unrecorded, so config.json and the journal's cutoffs are read by the
/// app's own decoder as in production; its Info.plist declares those modes
/// and not `--resume-frozen`.
struct PatchedBackstop {
    let dir: URL
    let script: URL
    let home: URL

    struct PatchError: Error, CustomStringConvertible {
        let constant: String
        let hits: Int
        var description: String { "backstop.sh has \(hits) lines setting \(constant), not one" }
    }

    init(home: URL, dir: URL) throws {
        self.home = home
        self.dir = dir
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let calls = dir.appendingPathComponent("calls").path
        let thermal = dir.appendingPathComponent("thermal").path
        let battery = dir.appendingPathComponent("battery").path
        let stateAtSudo = dir.appendingPathComponent("state-at-sudo").path
        let namesAtSudo = dir.appendingPathComponent("names-at-sudo").path
        let logsAtSudo = dir.appendingPathComponent("logs-at-sudo").path
        let state = home.appendingPathComponent("state.json").path
        try "0".write(toFile: thermal, atomically: true, encoding: .utf8)
        try "25".write(toFile: battery, atomically: true, encoding: .utf8)
        let fakes: [String: String] = [
            "PMSET": #"""
            printf 'pmset %s\n' "$*" >> '\#(calls)'
            [[ "$*" == "-g batt" ]] || exit 99
            printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=4567)\t%s%%; discharging; 1:00 remaining present: true\n" "$(/bin/cat '\#(battery)')"
            """#,
            "NOTIFYUTIL": #"""
            printf 'notifyutil %s\n' "$*" >> '\#(calls)'
            printf 'com.apple.system.thermalpressurelevel %s\n' "$(/bin/cat '\#(thermal)')"
            """#,
            "SUDO": #"""
            printf 'sudo %s\n' "$*" >> '\#(calls)'
            /bin/cp '\#(state)' '\#(stateAtSudo)' 2>/dev/null || /bin/rm -f '\#(stateAtSudo)'
            /bin/ls -a '\#(home.path)' > '\#(namesAtSudo)'
            /bin/ls -a '\#(home.path)/Logs' > '\#(logsAtSudo)' 2>/dev/null || : > '\#(logsAtSudo)'
            """#,
            "IOREG": "exit 0",
            "PS": "exit 1",
            "SYSCTL": "echo fake-boot",
            "KILL": #"printf 'kill %s\n' "$*" >> '\#(calls)'; exit 1"#,
            "DEFAULTS": #"printf 'defaults %s\n' "$*" >> '\#(calls)'; exit 1"#,
            "INSOMNIA_BIN": #"""
            [[ "${1:-}" == --agent-cutoffs || "${1:-}" == --agent-session-cutoffs ]] && exec '\#(BuiltApp.binary.path)' "$@"
            exit 1
            """#,
        ]
        var constants = [String: String]()
        for (name, body) in fakes {
            let fake = dir.appendingPathComponent(name.lowercased())
            try "#!/bin/bash\n\(body)\n".write(to: fake, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            constants[name] = fake.path
        }
        let info = dir.appendingPathComponent("Info.plist")
        try BuiltApp.infoPlist(agentCutoffsVersion: "\(AgentCutoffsCommand.version)").write(to: info, atomically: true, encoding: .utf8)
        constants["INSOMNIA_INFO"] = info.path
        let source = try ScriptSource.shared.lines("backstop.sh", setting: Array(constants.keys))
        var lines = source.lines
        for (name, value) in constants {
            let hits = source.hits[name] ?? []
            guard hits.count == 1 else { throw PatchError(constant: name, hits: hits.count) }
            lines[hits[0]] = "\(name)='\(value)'"
        }
        script = dir.appendingPathComponent("backstop.sh")
        try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
    }

    func setThermal(_ level: Int) throws {
        try "\(level)".write(to: dir.appendingPathComponent("thermal"), atomically: true, encoding: .utf8)
    }

    func setBattery(_ percent: Int) throws {
        try "\(percent)".write(to: dir.appendingPathComponent("battery"), atomically: true, encoding: .utf8)
    }

    struct RunError: Error, CustomStringConvertible {
        let description: String
    }

    /// What the last run printed on standard output and standard error,
    /// kept in `dir` (last.stdout, last.stderr) rather than thrown away.
    var lastStdout: String { String(decoding: read("last.stdout") ?? Data(), as: UTF8.self) }
    var lastStderr: String { String(decoding: read("last.stderr") ?? Data(), as: UTF8.self) }

    /// The bytes of `name` in `dir`, or nil when there is no such file. A
    /// file that is there but cannot be read fails the test instead of
    /// reading as missing, so an unread record never passes for no calls.
    private func read(_ name: String) -> Data? {
        let url = dir.appendingPathComponent(name)
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            XCTFail("could not read \(url.path): \(error)")
            return nil
        }
    }

    /// One run, as launchd starts it, or with another PATH. Returns its
    /// exit status once it has exited and been reaped. What it prints goes
    /// to `lastStdout` and `lastStderr`. A run that cannot be started
    /// throws, and so does one a signal ended, which has no exit status:
    /// its error carries the signal and what the run printed on standard
    /// error. The fakes call every tool by its full path.
    func run(path: String = "/usr/bin:/bin:/usr/sbin:/sbin") async throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.environment = ["PATH": path, "INSOMNIA_HOME": home.path, "HOME": home.path]
        let out = dir.appendingPathComponent("last.stdout")
        let err = dir.appendingPathComponent("last.stderr")
        for url in [out, err] {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw RunError(description: "could not create \(url.path) for the run's output")
            }
        }
        let outHandle = try FileHandle(forWritingTo: out)
        defer { try? outHandle.close() }
        let errHandle = try FileHandle(forWritingTo: err)
        defer { try? errHandle.close() }
        p.standardOutput = outHandle
        p.standardError = errHandle
        let exit = ProcessExit(p)
        try p.run()
        await exit.exited()
        guard p.terminationReason == .exit else {
            throw RunError(description: "backstop.sh ended on signal \(p.terminationStatus); stderr: \(lastStderr)")
        }
        return p.terminationStatus
    }

    /// Runs each agent once, at most `width` at a time, and returns their
    /// exit statuses in order. The agents must act on separate homes. The
    /// runs whose copy has a shortened read limit (`setCommandTimeout`),
    /// for a binary that does not answer, start first: each waits that
    /// limit out, and one started last would hold the table up alone.
    /// Every run that started is waited for, also when another fails to
    /// start: the group waits for its tasks before it throws.
    static func runAll(_ agents: [PatchedBackstop], width: Int = 16) async throws -> [Int32] {
        var statuses = [Int32](repeating: -1, count: agents.count)
        let shortened = try agents.map { try $0.readLimitIsShortened() }
        let order = agents.indices.filter { shortened[$0] } + agents.indices.filter { !shortened[$0] }
        try await withThrowingTaskGroup(of: (Int, Int32).self) { group in
            var next = 0
            func add() {
                guard next < order.count else { return }
                let (i, agent) = (order[next], agents[order[next]])
                group.addTask { (i, try await agent.run()) }
                next += 1
            }
            for _ in 0..<width { add() }
            while let (i, status) = try await group.next() {
                statuses[i] = status
                add()
            }
        }
        return statuses
    }

    /// Removes the calls record. Only a record that is not there counts as
    /// removed; any other failure throws, so calls that stay cannot pass
    /// for calls of the next run.
    func clearCalls() throws {
        do {
            try FileManager.default.removeItem(at: dir.appendingPathComponent("calls"))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    var calls: [String] {
        String(decoding: read("calls") ?? Data(), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Makes every sudo call fail (exit 1) after it is recorded: the
    /// restore does not happen.
    func failSudo() throws {
        let sudo = dir.appendingPathComponent("sudo")
        try (String(contentsOf: sudo, encoding: .utf8) + "exit 1\n").write(to: sudo, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sudo.path)
    }

    /// Points MKTEMP at /usr/bin/false, so the agent cannot create the
    /// record aside (ended-session.json.<8 letters or digits>). In a folder
    /// that really takes no new file the agent's status files fail too;
    /// RecoveryScriptTests runs that case.
    func refuseRecordsAside() throws {
        try patch("MKTEMP=/usr/bin/mktemp", "MKTEMP=/usr/bin/false")
    }

    /// Sets LOCK_RECORD_MAX_BYTES to 0, so no record fits in the recovery
    /// lock file and the agent writes none there: a stand-in for a lock
    /// file that refuses the write (a full disk). Content already in the
    /// file then reads as more than any record, which ends no session.
    func refuseLockRecord() throws {
        try patch("LOCK_RECORD_MAX_BYTES=1048576", "LOCK_RECORD_MAX_BYTES=0")
    }

    /// Points CAT at a fake that fails on the recovery lock file and runs
    /// /bin/cat on anything else, so the agent cannot read the lock file
    /// back after it writes a record there, and reads session.json and its
    /// other files as usual. With `times`, only the first that many reads
    /// of the lock file fail, as a passing error would (`lockReads()`
    /// counts them).
    func failLockReadBack(times: Int? = nil) throws {
        let cat = dir.appendingPathComponent("cat")
        let reads = dir.appendingPathComponent("lock-reads")
        try #"""
        #!/bin/bash
        if [[ "${1:-}" == */.recovery.lock ]]; then
          n=$(( $(/bin/cat '\#(reads.path)' 2>/dev/null || echo 0) + 1 ))
          echo "$n" > '\#(reads.path)'
          (( n > \#(times ?? Int.max) )) || exit 1
        fi
        exec /bin/cat "$@"

        """#.write(to: cat, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cat.path)
        try patch("CAT=/bin/cat", "CAT='\(cat.path)'")
    }

    /// How many times the agent read the recovery lock file through the
    /// fake of `failLockReadBack`: 0 before the first read, which makes
    /// the count file.
    func lockReads() throws -> Int {
        let url = dir.appendingPathComponent("lock-reads")
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let count = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw RunError(description: "lock-reads holds \(text.debugDescription), not a count")
        }
        return count
    }

    /// Points RM at a fake that sets the user append-only flag (chflags
    /// uappnd) on `lock` when the agent removes `session`, then runs
    /// /bin/rm. The run opened its fd 9 on the lock file before, so from
    /// then on the file takes appends (`>>`) and no write that empties it
    /// (`>`). The test clears the flag.
    func makeLockAppendOnly(whenRemoving session: URL, lock: URL) throws {
        let rm = dir.appendingPathComponent("rm")
        try #"""
        #!/bin/bash
        [[ "${1:-}" == -f && "${2:-}" == '\#(session.path)' ]] && /usr/bin/chflags uappnd '\#(lock.path)'
        exec /bin/rm "$@"

        """#.write(to: rm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rm.path)
        try patch("RM=/bin/rm", "RM='\(rm.path)'")
    }

    /// Sets LOG_RECORD_MAX_BYTES to 0, so no session.json fits in an end
    /// record in insomnia.log: the agent writes none there and reads none
    /// back, a stand-in for a log that refuses the line (a full disk).
    func refuseLogRecord() throws {
        try patch("LOG_RECORD_MAX_BYTES=65536", "LOG_RECORD_MAX_BYTES=0")
    }

    /// Points GREP at a fake that finds no end record line in a log (exit
    /// 1 for `-Fxq -e insomnia-ended-session-v1 ...`) and runs /usr/bin/grep
    /// on anything else: the agent's line goes into insomnia.log, but
    /// neither the read-back nor a later run finds it.
    func failLogReadBack() throws {
        let grep = dir.appendingPathComponent("grep")
        try #"""
        #!/bin/bash
        [[ "${1:-}" == -Fxq && "${2:-}" == -e && "${3:-}" == "insomnia-ended-session-v1 "* ]] && exit 1
        exec /usr/bin/grep "$@"

        """#.write(to: grep, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: grep.path)
        try patch("GREP=/usr/bin/grep", "GREP='\(grep.path)'")
    }

    /// Points GREP at a fake that, each time the agent looks for an end
    /// record line, first appends `cut sh` without a newline to `log`
    /// unless the log already ends mid-line, then runs /usr/bin/grep: a
    /// line some other write left cut short sits at the end of the log
    /// whenever the agent writes there after a check, its record included.
    func cutTheLogShortAtEveryRecordCheck(log: URL) throws {
        let grep = dir.appendingPathComponent("grep")
        try #"""
        #!/bin/bash
        if [[ "${1:-}" == -Fxq && "${2:-}" == -e && "${3:-}" == "insomnia-ended-session-v1 "* ]]; then
          if [[ ! -s '\#(log.path)' || "$(/usr/bin/tail -c 1 '\#(log.path)'; printf x)" == $'\nx' ]]; then
            printf 'cut sh' >> '\#(log.path)'
          fi
        fi
        exec /usr/bin/grep "$@"

        """#.write(to: grep, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: grep.path)
        try patch("GREP=/usr/bin/grep", "GREP='\(grep.path)'")
    }

    /// Points GREP at a fake that, each time the agent looks for an end
    /// record line while no other writer holds insomnia.log's lock (lockf
    /// -t 0 gets it), first asks another writer to take that lock, write
    /// `held sh`, wait a second, then write `ort`, still without a newline,
    /// and let go. The writer is a thread in the test process (LogWriters)
    /// that takes the lock with flock, as lockf does. The fake runs
    /// /usr/bin/grep once that writer says it holds the lock, or after 5 s
    /// without it. So the agent's write after such a check, its record
    /// included, waits for that writer and finds the log ends in a line cut
    /// short. A check while the lock is held (the agent's own read-back)
    /// asks for no writer. Settle the writers before the home goes.
    func holdTheLogAtEveryRecordCheck(log: URL) throws -> LogWriters {
        let grep = dir.appendingPathComponent("grep")
        let writers = try LogWriters(dir: dir.appendingPathComponent("log-writers", isDirectory: true), log: log)
        let requests = writers.requests.path
        let acks = writers.acks.path
        try #"""
        #!/bin/bash
        # A request is a file in the requests folder, made under a dot name
        # and renamed, so the writer sees it whole. The writer makes the file
        # of the same name in the acks folder once it holds the lock. The fake
        # records whether that came in time in the seen or late folder.
        if [[ "${1:-}" == -Fxq && "${2:-}" == -e && "${3:-}" == "insomnia-ended-session-v1 "* && -f '\#(log.path)' ]] \
           && /usr/bin/lockf -k -s -t 0 '\#(log.path)' /usr/bin/true; then
          if made=$(/usr/bin/mktemp '\#(requests)/.XXXXXX') && id=${made##*/.} && /bin/mv "$made" '\#(requests)/'"$id"; then
            answered=""
            for _ in $(/usr/bin/jot 500); do
              if [[ -e '\#(acks)/'"$id" ]]; then answered=1; break; fi
              /bin/sleep 0.01
            done
            if [[ -n "$answered" ]]; then : > '\#(writers.seen.path)/'"$id"; else : > '\#(writers.late.path)/'"$id"; fi
          else
            printf 'the fake grep could not make a request\n' >> '\#(writers.failures.path)'
          fi
        fi
        exec /usr/bin/grep "$@"

        """#.write(to: grep, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: grep.path)
        try patch("GREP=/usr/bin/grep", "GREP='\(grep.path)'")
        return writers
    }

    /// The writer holdTheLogAtEveryRecordCheck's fake asks for: one thread
    /// in the test process, so no process outlives the test and none needs
    /// reaping. For each request, in the order it finds them, it opens the
    /// log, takes its lock with flock (waiting up to 5 s), writes `held sh`,
    /// acknowledges the request, waits a second, writes `ort` and closes the
    /// log, which lets the lock go. Each write and file operation is
    /// checked. `settle` stops the thread and checks that it served every
    /// request and that every fake saw its acknowledgment in time.
    final class LogWriters: @unchecked Sendable {
        /// The thread did not finish in time and may still write to the log.
        struct Unsettled: Error, CustomStringConvertible {
            let description: String
        }

        let requests: URL
        let acks: URL
        let seen: URL
        let late: URL
        /// What the fake could not do, one line each.
        let failures: URL
        private let log: URL
        private let lock = NSLock()
        private let finished = DispatchSemaphore(value: 0)
        private var stopping = false
        /// Each request served, in order, with the writer's status: 0, 75
        /// when the lock stayed taken for 5 s, 74 when a write or file
        /// operation failed.
        private var served: [(id: String, status: Int32)] = []
        private var problems: [String] = []
        private var settling: Task<[Int32], Error>?

        init(dir: URL, log: URL) throws {
            self.log = log
            requests = dir.appendingPathComponent("requests", isDirectory: true)
            acks = dir.appendingPathComponent("acks", isDirectory: true)
            seen = dir.appendingPathComponent("seen", isDirectory: true)
            late = dir.appendingPathComponent("late", isDirectory: true)
            failures = dir.appendingPathComponent("failures")
            for folder in [requests, acks, seen, late] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let thread = Thread { [self] in serve() }
            thread.name = "PatchedBackstop.LogWriters"
            thread.start()
        }

        private func note(_ problem: String) { lock.withLock { problems.append(problem) } }

        /// Serves requests every 10 ms until asked to stop. A scan that
        /// starts after the stop request and finds nothing new ends it, so a
        /// request made before `settle` is served.
        private func serve() {
            defer { finished.signal() }
            var done = Set<String>()
            while true {
                let stop = lock.withLock { stopping }
                let names: [String]
                do {
                    names = try FileManager.default.contentsOfDirectory(atPath: requests.path).filter { !$0.hasPrefix(".") }.sorted()
                } catch {
                    note("could not list \(requests.path): \(error)")
                    return
                }
                let new = names.filter { !done.contains($0) }
                for id in new {
                    let status = serveRequest(id)
                    done.insert(id)
                    lock.withLock { served.append((id, status)) }
                }
                if stop && new.isEmpty { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        private func serveRequest(_ id: String) -> Int32 {
            let fd = open(log.path, O_WRONLY | O_APPEND | O_CLOEXEC)
            guard fd >= 0 else {
                note("request \(id): could not open \(log.path): errno \(errno)")
                return 74
            }
            var status = hold(fd, for: id)
            // Closing the log lets its lock go.
            if close(fd) != 0 {
                note("request \(id): closing the log: errno \(errno)")
                status = 74
            }
            return status
        }

        private func hold(_ fd: Int32, for id: String) -> Int32 {
            let deadline = Date().addingTimeInterval(5)
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EINTR else {
                    note("request \(id): flock: errno \(errno)")
                    return 74
                }
                if Date() >= deadline { return 75 }
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard append("held sh", to: fd, for: id) else { return 74 }
            let ack = acks.appendingPathComponent(id).path
            let made = open(ack, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard made >= 0 else {
                note("request \(id): could not make \(ack): errno \(errno)")
                return 74
            }
            guard close(made) == 0 else {
                note("request \(id): closing \(ack): errno \(errno)")
                return 74
            }
            Thread.sleep(forTimeInterval: 1)
            return append("ort", to: fd, for: id) ? 0 : 74
        }

        private func append(_ text: String, to fd: Int32, for id: String) -> Bool {
            var bytes = Array(text.utf8)[...]
            while !bytes.isEmpty {
                let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    bytes = bytes.dropFirst(n)
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    note("request \(id): writing \(text.debugDescription) to the log: \(n), errno \(errno)")
                    return false
                }
            }
            return true
        }

        /// Stops the writer and returns each request's status in the order
        /// it was served, once the thread has finished. Throws `Unsettled`
        /// when it has not finished within 30 s of the stop request, which
        /// is far longer than a request takes (at most 5 s for the lock and
        /// one second held). Throws when a write or file operation failed,
        /// a request was not served, or a fake did not see its
        /// acknowledgment in time. Every call, also one made while another
        /// is waiting, gets the outcome of the first.
        @discardableResult
        func settle() async throws -> [Int32] {
            let task = lock.withLock { () -> Task<[Int32], Error> in
                if let settling { return settling }
                stopping = true
                let task = Task.detached { [self] in try await join() }
                settling = task
                return task
            }
            return try await task.value
        }

        private func join() async throws -> [Int32] {
            let finished = self.finished
            let joined = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global().async { done.resume(returning: finished.wait(timeout: .now() + 30) == .success) }
            }
            guard joined else {
                throw Unsettled(description: "the log writer did not finish within 30 s of the stop request and may still write to \(log.path)")
            }
            let (served, problems) = lock.withLock { (self.served, self.problems) }
            func names(_ folder: URL) throws -> Set<String> {
                Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") })
            }
            let requested = try names(requests)
            let seenNames = try names(seen)
            let lateNames = try names(late)
            var failed = ""
            if FileManager.default.fileExists(atPath: failures.path) {
                failed = try String(contentsOf: failures, encoding: .utf8)
            }
            let ids = served.map(\.id)
            guard problems.isEmpty, failed.isEmpty, lateNames.isEmpty, Set(ids) == requested, ids.count == requested.count, seenNames == requested else {
                throw RunError(description: "the log writer served \(served) of requests \(requested.sorted()); acknowledged in time \(seenNames.sorted()), late \(lateNames.sorted()); problems \(problems); the fake's failures \(failed.debugDescription)")
            }
            return served.map(\.status)
        }
    }

    private func patch(_ line: String, _ replacement: String) throws {
        let text = try String(contentsOf: script, encoding: .utf8)
        let hits = text.components(separatedBy: "\n").filter { $0 == line }.count
        guard hits == 1 else { throw PatchError(constant: String(line.prefix { $0 != "=" }), hits: hits) }
        try text.replacingOccurrences(of: "\n\(line)\n", with: "\n\(replacement)\n").write(to: script, atomically: true, encoding: .utf8)
    }

    /// The call that restores sleep.
    var restoreCall: String { "sudo -n \(dir.appendingPathComponent("pmset").path) -a disablesleep 0" }

    /// state.json as the last sudo call found it, or nil when there was none.
    var stateAtSudo: Data? { read("state-at-sudo") }

    /// The names in INSOMNIA_HOME as the last sudo call found them.
    var namesAtSudo: [String] {
        String(decoding: read("names-at-sudo") ?? Data(), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The names in INSOMNIA_HOME/Logs as the last sudo call found them.
    var logsAtSudo: [String] {
        String(decoding: read("logs-at-sudo") ?? Data(), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Makes the app binary unusable for the agent: its Info.plist then
    /// declares no `--agent-cutoffs` version, so the binary is not run.
    func withdrawAgentCutoffs() throws {
        try BuiltApp.infoPlist(agentCutoffsVersion: nil).write(to: dir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    }

    /// The app binary the agent runs (INSOMNIA_BIN).
    var appBinary: URL { dir.appendingPathComponent("insomnia_bin") }

    /// Replaces the app binary with a script running `body`.
    func replaceAppBinary(with body: String) throws {
        try "#!/bin/bash\n\(body)\n".write(to: appBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appBinary.path)
    }

    /// Sets LOG_LOCK_TIMEOUT_SECONDS, the longest each of the agent's
    /// writes to insomnia.log waits for the log's lock, in this copy.
    func setLogLockTimeout(_ seconds: Int) throws {
        try patch("LOG_LOCK_TIMEOUT_SECONDS=5", "LOG_LOCK_TIMEOUT_SECONDS=\(seconds)")
    }

    /// Sets COMMAND_TIMEOUT_SECONDS, the limit on each read, in this copy.
    func setCommandTimeout(_ seconds: Int) throws {
        let text = try String(contentsOf: script, encoding: .utf8)
        let line = "COMMAND_TIMEOUT_SECONDS=30"
        guard text.components(separatedBy: "\n").filter({ $0 == line }).count == 1 else { throw PatchError(constant: "COMMAND_TIMEOUT_SECONDS", hits: 0) }
        try text.replacingOccurrences(of: "\n\(line)\n", with: "\nCOMMAND_TIMEOUT_SECONDS=\(seconds)\n").write(to: script, atomically: true, encoding: .utf8)
    }

    /// Whether setCommandTimeout has changed this copy's limit on each read
    /// from the 30 s backstop.sh sets.
    func readLimitIsShortened() throws -> Bool {
        let text = try String(contentsOf: script, encoding: .utf8)
        return !text.components(separatedBy: "\n").contains("COMMAND_TIMEOUT_SECONDS=30")
    }
}
