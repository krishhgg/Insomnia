import Darwin
import Foundation
import XCTest
@testable import Insomnia

/// `Insomnia --access-lists`: the one-shot mode backstop.sh and
/// uninstall.sh use to read access control lists. The mapping is tested
/// with an injected reader, so no real list is read; the built binary is
/// compared with the app's own reader only where SystemIntegration allows
/// real lists to be read.
final class AccessListsCommandTests: XCTestCase {
    private let me = getuid()

    /// Runs the mode with `lists` as what each path reads, recording each
    /// read and the lifetime in `events`. The lifetime is recorded, never
    /// armed: an alarm would end the test runner.
    private func run(_ arguments: [String], _ lists: [String: AccessList] = [:], events: Locked<[String]> = Locked([])) -> AccessListsCommand.Output? {
        AccessListsCommand.run(
            arguments,
            read: { path in
                events.value.append("read \(path)")
                return lists[path] ?? .entries([])
            },
            user: me,
            endAfter: { events.value.append("end after \($0)") }
        )
    }

    /// Other command lines are not this mode: nothing is read and no
    /// lifetime is armed.
    func testOtherCommandLinesAreNotThisMode() {
        let events = Locked<[String]>([])
        for arguments in [[], ["-NSDocumentRevisionsDebugMode", "YES"], ["--resume-frozen", "30"], ["/a", "--access-lists", "30", "/a"], ["--access-list", "30", "/a"]] {
            XCTAssertNil(run(arguments, events: events), "\(arguments)")
        }
        XCTAssertEqual(events.value, [], "the menu bar app must never get a lifetime or read a list")
    }

    /// A missing or malformed lifetime, no path, or a path that is not
    /// absolute answers the single line "usage" with EX_USAGE, before any
    /// list is read or any lifetime is armed.
    func testMalformedArgumentsAreAUsageErrorWithoutARead() {
        let events = Locked<[String]>([])
        let bad: [[String]] = [
            ["--access-lists"],
            ["--access-lists", "30"],
            ["--access-lists", "/a"],
            ["--access-lists", "0", "/a"],
            ["--access-lists", "301", "/a"],
            ["--access-lists", "1000", "/a"],
            ["--access-lists", "x", "/a"],
            ["--access-lists", " 30", "/a"],
            ["--access-lists", "-1", "/a"],
            ["--access-lists", "30", "a"],
            ["--access-lists", "30", ""],
            ["--access-lists", "30", "/a", "b"],
            ["--access-lists", "30", "./a"],
        ]
        for arguments in bad {
            XCTAssertEqual(run(arguments, events: events), .init(lines: ["usage"], status: 64), "\(arguments)")
        }
        XCTAssertEqual(events.value, [], "a list read or a lifetime armed from bad arguments")
    }

    /// The lifetime is armed with the caller's number of seconds before the
    /// first list is read, so a read that blocks still ends on time. Each
    /// path is read once, in order, repeats included.
    func testTheLifetimeIsArmedBeforeAnyListIsRead() {
        let events = Locked<[String]>([])
        for (argument, seconds) in [("1", UInt32(1)), ("33", 33), ("300", 300), ("007", 7)] {
            events.value = []
            let output = run(["--access-lists", argument, "/b", "/a", "/b"], events: events)
            XCTAssertEqual(output, .init(lines: ["none", "none", "none"], status: 0), argument)
            XCTAssertEqual(events.value, ["end after \(seconds)", "read /b", "read /a", "read /b"], argument)
        }
    }

    /// The word for each list, for this user's receipt. installed is
    /// exactly the entry install.sh adds for this uid; any other list with
    /// an entry that allows something is allows, also when ls would print
    /// it as the installed one (synchronize, delete_child, inheritance
    /// flags); a list of deny entries alone is denies. A list read in part,
    /// or not at all, is not whole.
    func testEveryListHasItsWord() {
        let installed = AccessEntry.installed(for: me)
        func changed(_ change: (inout AccessEntry) -> Void) -> AccessEntry {
            var entry = installed
            change(&entry)
            return entry
        }
        let deny = AccessEntry(allows: false, principal: .user(1), rights: ["read"], flags: [])
        let cases: [(name: String, list: AccessList, word: AccessListsCommand.Word, text: String, whole: Bool)] = [
            ("no list", .entries([]), .none, "none", true),
            ("the entry install.sh adds", .entries([installed]), .installed, "installed", true),
            ("another account's entry", .entries([.installed(for: me &+ 1)]), .allows, "allows", true),
            ("read and synchronize", .entries([changed { $0.rights.insert("synchronize") }]), .allows, "allows", true),
            ("read and delete_child", .entries([changed { $0.rights.insert("delete_child") }]), .allows, "allows", true),
            ("file_inherit", .entries([changed { $0.flags.insert("file_inherit") }]), .allows, "allows", true),
            ("inherited", .entries([changed { $0.flags.insert("inherited") }]), .allows, "allows", true),
            ("the entry twice", .entries([installed, installed]), .allows, "allows", true),
            ("the entry and a deny entry", .entries([installed, deny]), .allows, "allows", true),
            ("a deny entry", .entries([deny]), .denies, "denies", true),
            ("the entry as a deny entry", .entries([changed { $0.allows = false }]), .denies, "denies", true),
            ("unreadable", .unreadable(EACCES), .unreadable(EACCES), "unreadable \(EACCES)", false),
            ("incomplete", .incomplete, .incomplete, "incomplete", false),
        ]
        for c in cases {
            let word = AccessListsCommand.word(c.list, user: me)
            XCTAssertEqual(word, c.word, c.name)
            XCTAssertEqual(word.text, c.text, c.name)
            XCTAssertEqual(word.whole, c.whole, c.name)
            XCTAssertEqual(run(["--access-lists", "30", "/r"], ["/r": c.list]), .init(lines: [c.text], status: c.whole ? 0 : 1), c.name)
        }
        XCTAssertNil(SleepOffReceipts.receiptAccessProblem([installed], user: me), "installed is what the app's own check takes")
    }

    /// One line per path, in order, and exit 1 when any one list was not
    /// read whole, wherever it is.
    func testOneWordPerPathAndTheStatusOfTheWhole() {
        let lists: [String: AccessList] = ["/r": .entries([.installed(for: me)]), "/u": .unreadable(ENOENT), "/i": .incomplete]
        XCTAssertEqual(run(["--access-lists", "30", "/r", "/f", "/"], lists), .init(lines: ["installed", "none", "none"], status: 0))
        XCTAssertEqual(run(["--access-lists", "30", "/r", "/u", "/"], lists), .init(lines: ["installed", "unreadable \(ENOENT)", "none"], status: 1))
        XCTAssertEqual(run(["--access-lists", "30", "/i", "/r"], lists), .init(lines: ["incomplete", "installed"], status: 1))
    }

    /// A path lstat(2) cannot find is unreadable with its errno, and no
    /// list call is made for it: acl_get_link_np(3) answers ENOENT for a
    /// path with no list too, so the two must not be confused. The path is
    /// a name in a folder this test makes and leaves empty, so lstat fails
    /// and nothing reads a real list.
    func testAPathThatIsNotThereIsUnreadable() throws {
        let home = TempHome()
        defer { home.destroy() }
        let missing = home.root.appendingPathComponent("missing-\(UUID().uuidString)").path
        var info = stat()
        XCTAssertNotEqual(lstat(missing, &info), 0)
        XCTAssertEqual(AccessListsCommand.native(missing), .unreadable(ENOENT))
    }

    private var builtBinary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Insomnia")
    }

    /// Runs the real binary with `arguments`, an empty standard input, and
    /// INSOMNIA_HOME in a temp dir so it never touches ~/Library. Standard
    /// output and error are files: nothing to drain, nothing to deadlock.
    private func runBinary(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let home = TempHome()
        defer { home.destroy() }
        let outURL = home.root.appendingPathComponent("stdout")
        let errURL = home.root.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: outURL)
        let stderr = try FileHandle(forWritingTo: errURL)
        defer { try? stdout.close(); try? stderr.close() }
        let p = Process()
        p.executableURL = builtBinary
        p.arguments = arguments
        p.environment = ["INSOMNIA_HOME": home.root.path, "PATH": "/usr/bin:/bin"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = stdout
        p.standardError = stderr
        let exit = ProcessExit(p)
        try p.run()
        exit.wait()
        return (p.terminationStatus,
                (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }

    /// The real binary answers before AppKit starts, with the words the
    /// app's own reader gives for the same paths (read-only; nothing is
    /// changed), and a usage error exits 64 at once. The paths are this
    /// user's home folder, folders of the system's, /, and a path that is
    /// not there.
    func testBuiltBinaryReadsTheListsTheAppReads() throws {
        try SystemIntegration.require("real access control lists read")
        guard FileManager.default.isExecutableFile(atPath: builtBinary.path) else {
            throw XCTSkip("no built Insomnia executable at \(builtBinary.path)")
        }
        let usage = try runBinary(["--access-lists", "30", "relative"])
        XCTAssertEqual(usage.status, 64)
        XCTAssertEqual(usage.stdout, "usage\n")
        XCTAssertTrue(usage.stderr.contains("usage: Insomnia --access-lists"), usage.stderr)

        let missing = NSTemporaryDirectory() + "insomnia-missing-\(UUID().uuidString)"
        let paths = [NSHomeDirectory(), "/private/var/db", "/usr/bin", "/", missing]
        let r = try runBinary(["--access-lists", "30"] + paths)
        let words = paths.map { AccessListsCommand.word(AccessListsCommand.native($0), user: getuid()) }
        XCTAssertEqual(words.last, .unreadable(ENOENT))
        XCTAssertEqual(r.stdout, words.map { $0.text + "\n" }.joined(), r.stderr)
        XCTAssertEqual(r.status, words.allSatisfy(\.whole) ? 0 : 1)
    }
}
