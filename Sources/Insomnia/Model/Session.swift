import Foundation

/// An active keep-awake session. `endsAt` is the only thing that keeps sleep
/// disabled; everything else is bookkeeping.
struct Session: Codable, Equatable, Sendable {
    var startedAt: Date
    var endsAt: Date
    /// Every extension applied, in order, in seconds.
    var extensions: [TimeInterval]
    /// A name no other session has, given at Start and kept through every
    /// extension. A settled start names the session it leaves to be resumed
    /// by it (`ResumedSession.id`), and a start names its own
    /// (`SleepOffAttempt.session`), so two sessions with the same times are
    /// told apart. nil in a session an older build wrote. Read leniently:
    /// an id that is not a string reads as nil, as the scripts ignore the
    /// key (session_shape_problems). Left out of the JSON when nil.
    var id: String?

    init(startedAt: Date, endsAt: Date, extensions: [TimeInterval] = [], id: String? = nil) {
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.extensions = extensions
        self.id = id
    }

    private enum CodingKeys: String, CodingKey { case startedAt, endsAt, extensions, id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endsAt = try c.decode(Date.self, forKey: .endsAt)
        extensions = try c.decode([TimeInterval].self, forKey: .extensions)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endsAt, forKey: .endsAt)
        try c.encode(extensions, forKey: .extensions)
        try c.encodeIfPresent(id, forKey: .id)
    }

    /// Whether `self` and `other` are the same session as far as their ids
    /// tell: equal ids, or nil when either has none (an older build's).
    func sameID(as other: String?) -> Bool? {
        guard let id, let other else { return nil }
        return id == other
    }

    /// Seconds left until `endsAt`, never negative.
    func remaining(at now: Date) -> TimeInterval {
        SessionMath.remaining(until: endsAt, at: now)
    }

    /// True once `now` reaches `endsAt`.
    func isExpired(at now: Date) -> Bool {
        SessionMath.isExpired(endsAt: endsAt, at: now)
    }

    /// Shape of the menu bar countdown, derived from the session's span so it
    /// survives a relaunch without another persisted field. Because
    /// `remaining` never exceeds this span, the shape always has room for the
    /// value. An extension widens the span and can promote the shape, which
    /// is a one-off change at a user action, never a per-tick one.
    var countdownShape: CountdownShape {
        CountdownShape(initialDuration: endsAt.timeIntervalSince(startedAt))
    }
}
