import Foundation

/// Atomic JSON persistence for the three files Insomnia keeps on disk.
/// Writes go to a temp file in the same directory and are renamed into place
/// so a crash mid-write can never leave a truncated session or state file.
struct Store: Sendable {
    let paths: Paths

    init(paths: Paths) {
        self.paths = paths
    }

    // MARK: Generic

    /// Dates are ISO 8601 (`2026-09-02T10:00:00Z`) so backstop.sh can parse
    /// them with `date -j -f`.
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Returns nil when the file does not exist. Throws on unreadable or
    /// undecodable content.
    func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Store.makeDecoder().decode(T.self, from: data)
    }

    /// Atomic write: temp file + rename(2).
    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try write(data: Store.makeEncoder().encode(value), to: url)
    }

    private func write(data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: [])
        if rename(tmp.path, url.path) != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw StoreError.rename(from: tmp.path, to: url.path, errno: err)
        }
    }

    /// Removes the file; a missing file is not an error.
    func remove(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Typed helpers

    func loadSession() throws -> Session? { try read(Session.self, from: paths.sessionFile) }
    func saveSession(_ s: Session) throws { try write(s, to: paths.sessionFile) }
    /// Removes session.json, then the record of its end, which means
    /// something only while the file it copies is there. A record that
    /// cannot be removed is left and logged: it matches no later
    /// session.json, but it is still a copy of the session's times.
    func deleteSession() throws {
        try remove(at: paths.sessionFile)
        do {
            try remove(at: paths.endedSessionFile)
        } catch {
            Log.error("could not remove \(paths.endedSessionFile.path) (\(error.localizedDescription)); it matches no session.json, so it ends nothing, but it stays until removed by hand")
        }
    }

    /// Whether session.json is a session already ended: ended-session.json
    /// holds its exact bytes (`recordSessionEnd`, or backstop.sh's
    /// record_end). False when either file is missing or unreadable.
    func sessionEndIsRecorded() -> Bool {
        guard let recorded = try? Data(contentsOf: paths.endedSessionFile),
              let current = try? Data(contentsOf: paths.sessionFile) else { return false }
        return recorded == current
    }

    /// For an end that could not remove session.json: copies its bytes to
    /// ended-session.json, so this app after a relaunch and backstop.sh treat
    /// the session as over. True only when the record now matches the file.
    func recordSessionEnd() -> Bool {
        if sessionEndIsRecorded() { return true }
        guard let current = try? Data(contentsOf: paths.sessionFile) else { return false }
        do {
            try write(data: current, to: paths.endedSessionFile)
        } catch {
            return false
        }
        return sessionEndIsRecorded()
    }

    /// Non-mutating. A journal that does not decode stays exactly where it
    /// is: it is the only record of what a previous run changed, and moving
    /// or rewriting it would let the next reader (this app, backstop.sh,
    /// uninstall.sh) see no journal and call the machine clean. The error
    /// names the file so a person can fix or move it.
    func loadState() throws -> RuntimeState? {
        do {
            return try read(RuntimeState.self, from: paths.stateFile)
        } catch let error as DecodingError {
            throw StoreError.corrupt(file: paths.stateFile.path, detail: Self.brief(error))
        }
    }
    func saveState(_ s: RuntimeState) throws { try write(s, to: paths.stateFile) }

    func loadConfig() throws -> Config? { try read(Config.self, from: paths.configFile) }
    func saveConfig(_ c: Config) throws { try write(c, to: paths.configFile) }

    /// False for a config.json written before `configVersion` existed.
    func configHasVersion() throws -> Bool {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.configFile))
        return (object as? [String: Any])?["configVersion"] != nil
    }

    /// One line about why decoding failed, fit for a notification.
    private static func brief(_ error: DecodingError) -> String {
        func path(_ c: DecodingError.Context) -> String {
            let p = c.codingPath.map(\.stringValue).joined(separator: ".")
            return p.isEmpty ? "" : "\(p): "
        }
        switch error {
        case let .dataCorrupted(c): return path(c) + c.debugDescription
        case let .keyNotFound(k, c): return path(c) + "missing key \(k.stringValue)"
        case let .typeMismatch(t, c): return path(c) + "expected \(t)"
        case let .valueNotFound(t, c): return path(c) + "missing \(t)"
        @unknown default: return String(describing: error)
        }
    }
}

enum StoreError: Error, LocalizedError {
    case rename(from: String, to: String, errno: Int32)
    case corrupt(file: String, detail: String)

    var errorDescription: String? {
        switch self {
        case let .rename(from, to, errno):
            return "rename \(from) -> \(to) failed: \(String(cString: strerror(errno)))"
        case let .corrupt(file, detail):
            return "\(file) could not be decoded (\(detail)); it was left in place"
        }
    }
}
