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
    /// waited stored for the old one, so the failover's report about the
    /// current one still stands.
    func isStored(for configuredSSID: String) -> Bool {
        guard case let .stored(stored) = self else { return false }
        return stored.ssid == HotspotSSID.normalized(configuredSSID)
    }
}

/// The hotspot password field's state apart from the view, so the rules
/// for which keychain answer sets the notice, and when the button reads
/// "Saved", can be tested without a window.
struct HotspotPasswordField: Equatable {
    /// What a save stored. The SSID is the one the store used, read when
    /// the save began.
    struct Stored: Equatable, Sendable {
        let ssid: String
        let password: String
    }

    /// A load or recheck in flight: its token and the SSID it read for.
    struct Read: Equatable {
        fileprivate let token: Int
        let ssid: String
    }

    /// A save or clear is waiting on the keychain, which may be showing a
    /// dialog. One at a time.
    private(set) var saving = false
    /// What the last successful save or clear stored; nil after a failed
    /// one, which may have left either password.
    private(set) var stored: Stored?
    /// Why the saved password could not be loaded or saved; under the field.
    private(set) var notice: String?
    /// Bumped by every load and recheck, and when a save begins and
    /// answers, so an answer that arrives after a newer one does not
    /// overwrite it.
    private var request = 0

    /// "Saved" only while both fields hold what the last save stored. An
    /// SSID typed while the save waited, or either field edited since,
    /// reads "Save": that SSID has no password yet.
    func buttonTitle(ssid: String, password: String) -> String {
        if saving { return "Saving\u{2026}" }
        let showing = Stored(ssid: HotspotSSID.normalized(ssid), password: password)
        return stored == showing ? "Saved" : "Save"
    }

    /// A load or recheck begins for the configured `ssid`; pass what this
    /// returns to `finishRead`.
    mutating func startRead(ssid: String) -> Read {
        request += 1
        return Read(token: request, ssid: HotspotSSID.normalized(ssid))
    }

    /// A load or recheck answered; `ssid` is the one configured now. Its
    /// notice is used unless a newer read began, a save answered, or the
    /// SSID changed since: the answer is about the old SSID's item. Returns
    /// whether it was used.
    mutating func finishRead(_ read: Read, ssid: String, notice: String?) -> Bool {
        guard read.token == request, read.ssid == HotspotSSID.normalized(ssid) else { return false }
        self.notice = notice
        return true
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
        return true
    }

    /// The save answered. Its outcome always sets the notice: it is the
    /// user's latest action. A recheck that began while it waited (the
    /// failover's report changed) read the keychain behind it on the one
    /// queue, so its answer arrives later and is dropped, instead of
    /// hiding why the save failed.
    mutating func finishSave(_ outcome: HotspotStoreOutcome) {
        saving = false
        request += 1
        switch outcome {
        case let .stored(stored):
            self.stored = stored
            notice = nil
        case let .failed(notice):
            stored = nil
            self.notice = notice
        }
    }
}
