import Foundation
import XCTest

/// Runs a test's body in a child xctest process, so a runtime trap in the
/// code under test (an `Int` conversion of 1e300, say) fails that one test
/// instead of ending the whole run. The parent starts the same bundle with
/// only this test selected and `INSOMNIA_TRAP_PROBE` naming it. The child
/// sees the variable and runs the body. The parent then checks that the
/// child exited normally and that the test passed there. A signal is
/// reported as a trap, with the end of the child's output.
enum TrapProbe {
    static let key = "INSOMNIA_TRAP_PROBE"

    /// The child gets this long to load the bundle and run the one test.
    static let timeout: TimeInterval = 120

    /// `testName` is the calling test's `name`. The body runs on the
    /// caller's actor, in the child only.
    static func run(
        _ testName: String,
        isolation: isolated (any Actor)? = #isolation,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async throws {
        if ProcessInfo.processInfo.environment[key] == testName {
            try await body()
            return
        }
        guard let selector = selector(testName) else {
            XCTFail("not a test name: \(testName)", file: file, line: line)
            return
        }
        let log = ProcessTestHome.root.appendingPathComponent("trap-probe-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: log)
        }

        let process = Process()
        let runner = CommandLine.arguments.first.map(URL.init(fileURLWithPath:))
        let bundle = Bundle(for: Anchor.self).bundlePath
        if let runner, runner.lastPathComponent == "xctest" {
            process.executableURL = runner
            process.arguments = ["-XCTest", selector, bundle]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", selector, bundle]
        }
        var environment = ProcessInfo.processInfo.environment
        environment[key] = testName
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        let ended = Ended()
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        let pid = process.processIdentifier
        let finished = await ended.wait(timeout: timeout)
        if !finished {
            process.terminate()
            await ended.wait()
        }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n")
        // `name` may leave out the module that the child's log line puts
        // before the class, so the check matches from the class on.

        if process.terminationReason == .uncaughtSignal {
            removeHome(of: pid)
            XCTFail("\(selector) trapped in its child process (signal \(process.terminationStatus)):\n\(tail)", file: file, line: line)
        } else if !finished {
            XCTFail("\(selector) did not finish in \(Int(timeout)) s in its child process:\n\(tail)", file: file, line: line)
        } else if process.terminationStatus != 0 {
            XCTFail("\(selector) failed in its child process (exit \(process.terminationStatus)):\n\(tail)", file: file, line: line)
        } else if !text.contains("\(testName.dropFirst(2).dropLast())]' passed") {
            XCTFail("\(selector) did not run in its child process:\n\(tail)", file: file, line: line)
        }
    }

    /// "-[InsomniaTests.DurationInputTests testX]" becomes
    /// "InsomniaTests.DurationInputTests/testX", the form `-XCTest` takes.
    static func selector(_ testName: String) -> String? {
        guard testName.hasPrefix("-["), testName.hasSuffix("]") else { return nil }
        let parts = testName.dropFirst(2).dropLast().split(separator: " ")
        guard parts.count == 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// A child that traps never runs the InsomniaTestHome loader's cleanup,
    /// so its home is removed here. Only its own: the loader names it after
    /// the child's pid.
    private static func removeHome(of pid: Int32) {
        let parent = ProcessTestHome.root.deletingLastPathComponent()
        let prefix = "insomnia-tests-process-\(pid)-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    private final class Anchor {}

    /// The child's exit, awaited with a time limit.
    private final class Ended: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            let resume = lock.withLock {
                done = true
                defer { waiters.removeAll() }
                return waiters
            }
            for waiter in resume { waiter.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let now = lock.withLock {
                    if done { return true }
                    waiters.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }

        /// True if the child exited within `timeout`.
        func wait(timeout: TimeInterval) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if lock.withLock({ done }) { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return lock.withLock { done }
        }
    }
}
