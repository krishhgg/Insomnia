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
    /// the save began; `removed` is the loaded account the save removed.
    struct Stored: Equatable, Sendable {
        let ssid: String
        let password: String
        let removed: String?

        init(ssid: String, password: String, removed: String? = nil) {
            self.ssid = ssid
            self.password = password
            self.removed = removed
        }

        var change: HotspotPasswordChange {
            HotspotPasswordChange(ssid: ssid, removed: removed)
        }
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
        let showing = stored?.ssid == HotspotSSID.normalized(ssid) && stored?.password == password
        return showing ? "Saved" : "Save"
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

/// The keychain reads and writes behind the field, kept apart from the
/// sheet so their ordering rules are tested without a window.
@MainActor
extension HotspotPasswordField {
    /// Loads the saved password into the field, without a keychain prompt.
    /// An item this build may not read leaves the field empty and says
    /// why, so the user re-enters it; saving then replaces the item (see
    /// `KeychainStore`). The read can wait behind a save, so a field
    /// edited meanwhile is kept, even one typed in and emptied again, and
    /// a password read for an SSID edited away meanwhile is not shown: the
    /// SSID configured now is read instead. That read is a peek: the
    /// account a later save moves the password from stays the one the
    /// sheet loaded, as it does for any SSID edit, so the old SSID's item
    /// is still removed.
    static func loadForField(
        _ request: HotspotPasswordField.Read,
        secrets: any HotspotSecretStore,
        finish: @MainActor (HotspotPasswordField.Read, (password: String, notice: String?))
            -> HotspotPasswordField.ReadAnswer
    ) async {
        await readForField(
            request,
            first: { await loadedPassword(secrets.load) },
            again: { await loadedPassword(secrets.peek) },
            finish: finish
        )
    }

    /// Runs a load or recheck for the field: `first` reads, and `finish`
    /// takes the answer. While the SSID was edited during the read,
    /// `finish` drops the answer, and `again` reads the SSID configured
    /// now, until an answer is used or dropped.
    static func readForField(
        _ request: HotspotPasswordField.Read,
        first: @MainActor () async -> (password: String, notice: String?),
        again: @MainActor () async -> (password: String, notice: String?),
        finish: @MainActor (HotspotPasswordField.Read, (password: String, notice: String?))
            -> HotspotPasswordField.ReadAnswer
    ) async {
        var answer = await first()
        var request = request
        while case .readAgain(let next) = finish(request, answer) {
            request = next
            answer = await again()
        }
    }

    /// A prompt-free load: the password for the field, or an empty field
    /// and a notice saying why it cannot be shown.
    static func loadedPassword(
        _ load: () async throws -> String?
    ) async -> (password: String, notice: String?) {
        do {
            return (try await load() ?? "", nil)
        } catch let error as KeychainError {
            return ("", error.problem.settingsNotice)
        } catch {
            return ("", HotspotPasswordProblem.error(error.localizedDescription).settingsNotice)
        }
    }

    /// The notice under the password field for the hotspot `ssid`
    /// configured now. A problem the failover reports about that hotspot
    /// shows as it is. A report about another SSID, one edited away since,
    /// does not apply, and a cleared report is not taken as "readable": it
    /// also clears when the session ends. Then the keychain is read again,
    /// without a prompt, and the notice says what that read finds. The
    /// field is left as the user has it, and the reread is a peek: a load
    /// would make an SSID typed since then the account a save moves the
    /// password from, and the old SSID's item would stay behind.
    static func hotspotNotice(
        reported: HotspotPasswordReport?, ssid: String, reread: () async throws -> String?
    ) async -> String? {
        if let problem = reported?.problem(for: ssid) { return problem.settingsNotice }
        return await loadedPassword(reread).notice
    }

    /// A save or clear answered. The failover's report goes, and the next
    /// outage notifies afresh, unless the report is about the hotspot
    /// configured now and the save neither stored for it nor removed its
    /// item (`HotspotPasswordReport.stands`).
    static func passwordStored(
        _ outcome: HotspotStoreOutcome, configuredSSID: String, services: AppServices?
    ) {
        guard case .stored(let stored) = outcome else { return }
        services?.hotspotPasswordChanged(stored.change, configuredSSID: configuredSSID)
    }

    /// Saves `password`, or clears the saved one when it is empty, and
    /// returns what was stored under which SSID and which loaded account
    /// it removed, or the notice for a failure. The store does the
    /// keychain work on `KeychainQueue`, so a save waiting on a keychain
    /// dialog waits there while the main actor (the battery floor, the
    /// deadline timer, End) carries on.
    static func storePassword(
        _ password: String, in secrets: any HotspotSecretStore
    ) async -> HotspotStoreOutcome {
        do {
            let change =
                if password.isEmpty {
                    try await secrets.delete()
                } else {
                    try await secrets.save(password)
                }
            return .stored(.init(ssid: change.ssid, password: password, removed: change.removed))
        } catch {
            Log.error("could not save hotspot password: \(error.localizedDescription)")
            return .failed(
                notice: "Could not save the hotspot password: \(error.localizedDescription)")
        }
    }
}
