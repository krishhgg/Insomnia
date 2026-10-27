import Foundation

/// Complete ownership required when creating an unlimited session.
struct SessionOwner: Equatable, Sendable {
    let pid: Int32
    let identity: ProcessIdentity
    let executable: String
}

/// An active keep-awake session: a timed deadline, or unlimited while its
/// owning app remains alive. Unlimited sessions are never resumed at launch.
struct Session: Codable, Equatable, Sendable {
    var startedAt: Date
    private(set) var endsAt: Date?
    /// Every timed extension applied, in order, in seconds.
    private(set) var extensions: [TimeInterval]
    private let ownership: Ownership

    /// Partial ownership is historical evidence, not a new-session owner.
    private enum Ownership: Equatable, Sendable {
        case complete(SessionOwner)
        case legacy(pid: Int32?, identity: ProcessIdentity?, executable: String?)
    }

    var owner: SessionOwner? {
        if case let .complete(owner) = ownership { return owner }
        return nil
    }

    var isUnlimited: Bool { endsAt == nil }

    /// A new timed session always has a deadline.
    init(startedAt: Date, endsAt: Date, extensions: [TimeInterval] = []) {
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.extensions = extensions
        self.ownership = .legacy(pid: nil, identity: nil, executable: nil)
    }

    /// Only decoding may admit an unlimited session with partial ownership.
    init(unlimitedStartedAt startedAt: Date, owner: SessionOwner, extensions: [TimeInterval] = []) {
        precondition(owner.pid > 0 && owner.executable.hasPrefix("/"))
        self.startedAt = startedAt
        self.endsAt = nil
        self.extensions = extensions
        self.ownership = .complete(owner)
    }

    mutating func extendDeadline(to newEnd: Date) {
        guard let endsAt else { return }
        extensions.append(newEnd.timeIntervalSince(endsAt))
        self.endsAt = newEnd
    }

    private enum Mode: String, Codable { case timed, unlimited }
    private enum CodingKeys: String, CodingKey {
        case mode, startedAt, endsAt, extensions, ownerPID, ownerIdentity, ownerExecutable
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        extensions = try c.decode([TimeInterval].self, forKey: .extensions)
        // Missing mode is legacy timed data, never an implicit unlimited session.
        let mode = c.contains(.mode) ? try c.decode(Mode.self, forKey: .mode) : .timed
        switch mode {
        case .timed:
            endsAt = try c.decode(Date.self, forKey: .endsAt)
        case .unlimited:
            guard try c.decodeIfPresent(Date.self, forKey: .endsAt) == nil else {
                throw DecodingError.dataCorruptedError(forKey: .endsAt, in: c, debugDescription: "An unlimited session cannot have a deadline")
            }
            endsAt = nil
        }
        let ownerPID = try c.decodeIfPresent(Int32.self, forKey: .ownerPID)
        let ownerIdentity = try c.decodeIfPresent(ProcessIdentity.self, forKey: .ownerIdentity)
        let ownerExecutable = try c.decodeIfPresent(String.self, forKey: .ownerExecutable)
        if let ownerExecutable, !ownerExecutable.hasPrefix("/") {
            throw DecodingError.dataCorruptedError(forKey: .ownerExecutable, in: c, debugDescription: "An owner executable must be an absolute path")
        }
        if mode == .unlimited, ownerPID.map({ $0 > 0 }) != true {
            throw DecodingError.dataCorruptedError(forKey: .ownerPID, in: c, debugDescription: "An unlimited session must name its owning process")
        }
        if let ownerPID, let ownerIdentity, let ownerExecutable {
            ownership = .complete(SessionOwner(pid: ownerPID, identity: ownerIdentity, executable: ownerExecutable))
        } else {
            // Preserve every available field without inventing missing evidence.
            ownership = .legacy(pid: ownerPID, identity: ownerIdentity, executable: ownerExecutable)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isUnlimited ? Mode.unlimited : Mode.timed, forKey: .mode)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endsAt, forKey: .endsAt)
        try c.encode(extensions, forKey: .extensions)
        // Keep the helper's flat wire schema, including partial legacy fields.
        switch ownership {
        case let .complete(owner):
            try c.encode(owner.pid, forKey: .ownerPID)
            try c.encode(owner.identity, forKey: .ownerIdentity)
            try c.encode(owner.executable, forKey: .ownerExecutable)
        case let .legacy(pid, identity, executable):
            try c.encodeIfPresent(pid, forKey: .ownerPID)
            try c.encodeIfPresent(identity, forKey: .ownerIdentity)
            try c.encodeIfPresent(executable, forKey: .ownerExecutable)
        }
    }

    /// Unlimited has no numeric remaining duration; presentation branches on mode.
    func remaining(at now: Date) -> TimeInterval {
        guard let endsAt else { return 0 }
        return SessionMath.remaining(until: endsAt, at: now)
    }

    func isExpired(at now: Date) -> Bool {
        guard let endsAt else { return false }
        return SessionMath.isExpired(endsAt: endsAt, at: now)
    }

    var countdownShape: CountdownShape {
        CountdownShape(initialDuration: endsAt?.timeIntervalSince(startedAt) ?? 0)
    }
}
