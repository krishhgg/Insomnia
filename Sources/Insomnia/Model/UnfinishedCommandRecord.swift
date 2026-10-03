import Foundation

/// A `sudo pmset` that did not stop on SIGTERM and still holds the recovery
/// lock (`Paths.unfinishedCommandFile`). Only read to name the command when
/// the lock is busy: after a crash or force quit, the relaunched app cannot
/// take the lock until the command exits, and says which one to stop.
struct UnfinishedCommandRecord: Codable, Equatable, Sendable {
    var pid: Int32
    var command: String
    var since: Date
}
