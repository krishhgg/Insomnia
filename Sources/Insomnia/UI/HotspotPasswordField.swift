import Foundation

/// What a save or clear in Settings did: the SSID and password it stored,
/// or the notice saying why it failed.
enum HotspotStoreOutcome: Equatable, Sendable {
    case stored(HotspotPasswordField.Stored)
    case failed(notice: String)

    var notice: String? {
        if case let .failed(notice) = self { return notice }
        return nil
    }

    /// Whether this stored the password for `configuredSSID`, the hotspot
    /// set now. A save that began under an SSID edited away while it
    /// waited stored for the old one, so it says nothing about the
    /// current one.
    func isStored(for configuredSSID: String) -> Bool {
        guard case let .stored(stored) = self else { return false }
        return stored.ssid == HotspotSSID.normalized(configuredSSID)
    }
}

/// The hotspot password field's state apart from the view, so the rules
/// for which keychain answer sets the notice or fills the field, and when
/// the button reads "Saved", can be tested without a window.
struct HotspotPasswordField: Equatable {
    /// What a save stored. The SSID is the one the store used, read when
    /// the save began.
    struct Stored: Equatable, Sendable {
        let ssid: String
        let password: String
    }

    /// A load or recheck in flight: its token, the SSID it read for, and
    /// for a load, the field's edit count when it began.
    struct Read: Equatable {
        fileprivate let token: Int
        let ssid: String
        /// nil for a recheck, which only sets the notice.
        fileprivate let edits: Int?
    }

    /// What `finishRead` made of an answer.
    enum ReadAnswer: Equatable {
        /// The answer set the notice, filled the field, or both.
        case used
        /// Nothing took the answer: a newer read, a save or a clear began
        /// since, and for a load, the field was edited.
        case dropped
        /// The SSID was edited while the read waited. The answer is about
        /// the old SSID's item and is dropped; read the SSID configured now
        /// with this read instead.
        case readAgain(Read)
    }

    /// A save or clear is waiting on the keychain, which may be showing a
    /// dialog. One at a time.
    private(set) var saving = false
    /// What the last successful save or clear stored; nil after a failed
    /// one, which may have left either password.
    private(set) var stored: Stored?
    /// Why the saved password could not be loaded or saved; under the field.
    private(set) var notice: String?
    /// What the password field shows: what the user typed, or the saved
    /// password a load filled in.
    private(set) var password = ""
    /// Bumped by every load and recheck, and when a save begins and
    /// answers, so a notice that arrives after a newer one does not
    /// overwrite it.
    private var request = 0
    /// Bumped by every edit of the password field and when a save begins,
    /// so a load fills the field only if neither happened since it began.
    private var edits = 0

    /// "Saved" only while both fields hold what the last save stored. An
    /// SSID typed while the save waited, or either field edited since,
    /// reads "Save": that SSID has no password yet.
    func buttonTitle(ssid: String) -> String {
        if saving { return "Saving\u{2026}" }
        let showing = Stored(ssid: HotspotSSID.normalized(ssid), password: password)
        return stored == showing ? "Saved" : "Save"
    }

    /// The user changed the password field. A load still waiting will not
    /// fill it, even if the field is empty again by the time it answers.
    mutating func edit(_ password: String) {
        guard password != self.password else { return }
        self.password = password
        edits += 1
    }

    /// The window loads the saved password for the configured `ssid`;
    /// pass what this returns to `finishRead`.
    mutating func startLoad(ssid: String) -> Read {
        request += 1
        return Read(token: request, ssid: HotspotSSID.normalized(ssid), edits: edits)
    }

    /// A recheck of the notice begins for the configured `ssid`; pass what
    /// this returns to `finishRead`. It never fills the field.
    mutating func startRead(ssid: String) -> Read {
        request += 1
        return Read(token: request, ssid: HotspotSSID.normalized(ssid), edits: nil)
    }

    /// A load or recheck answered with `password` and `notice`; `ssid` is
    /// the one configured now. The notice is used unless a newer read
    /// began or a save answered since. A load's password fills the field
    /// only if the field was empty when the load began and has not been
    /// edited since, and no save began; a newer recheck does not stop it.
    /// An SSID edited meanwhile drops the answer, since it is about the
    /// old SSID's item, and the SSID configured now is read instead, so
    /// the field is not left empty with no notice.
    mutating func finishRead(_ read: Read, ssid: String, password: String, notice: String?) -> ReadAnswer {
        let newest = read.token == request
        let fills = read.edits == edits && self.password.isEmpty
        guard newest || fills else { return .dropped }
        guard read.ssid == HotspotSSID.normalized(ssid) else {
            // A load that newer reads overtook keeps its old token: it may
            // still fill the field, but it no longer sets the notice.
            var token = read.token
            if newest {
                request += 1
                token = request
            }
            return .readAgain(Read(token: token, ssid: HotspotSSID.normalized(ssid), edits: fills ? read.edits : nil))
        }
        if newest { self.notice = notice }
        if fills { self.password = password }
        return .used
    }

    /// A save or clear begins; false while one is still waiting. A load
    /// or recheck that began before it read the keychain ahead of it on
    /// the one queue, so its answer is from before the save and is
    /// dropped: a load would otherwise refill a field the user had just
    /// cleared, and a later Save would store the old password again.
    mutating func startSave() -> Bool {
        guard !saving else { return false }
        saving = true
        request += 1
        edits += 1
        return true
    }

    /// The save answered; `ssid` is the one configured now. Its outcome
    /// always sets the notice: it is the user's latest action. A recheck
    /// that began while it waited (the failover's report changed, or the
    /// SSID was edited) read the keychain behind it on the one queue, so
    /// its answer arrives later and is dropped, instead of hiding why the
    /// save failed. A save that stored for an SSID edited away meanwhile
    /// says nothing about the one configured now: this returns the
    /// recheck to run for it.
    @discardableResult
    mutating func finishSave(_ outcome: HotspotStoreOutcome, ssid: String) -> Read? {
        saving = false
        request += 1
        switch outcome {
        case let .stored(stored):
            self.stored = stored
            notice = nil
            return outcome.isStored(for: ssid) ? nil : startRead(ssid: ssid)
        case let .failed(notice):
            stored = nil
            self.notice = notice
            return nil
        }
    }
}
