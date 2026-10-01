import Foundation
import Security

/// Reads the designated code requirement of signed code on disk, as text in
/// the requirement language. That is what the recovery LaunchAgent pins: it
/// runs `codesign --verify --strict -R=<text>` on the app bundle before it
/// executes the backstop.sh sealed inside (LaunchdBackstop, install.sh).
///
/// For an ad-hoc signature the designated requirement is the cdhash of the
/// signed code, `cdhash H"..."`, one per architecture slice, so it changes
/// with every build and no other bundle satisfies it. For a Developer ID
/// signature it names the bundle identifier and the team, so an upgrade
/// signed by the same team still satisfies it.
///
/// `SecRequirementCopyString` prints the same text as `codesign -d -r-`,
/// which install.sh reads; the two must agree for the app to recognise the
/// plist install.sh wrote (PackagingTests checks this on a scratch bundle).
enum CodeRequirement {
    struct ReadError: LocalizedError {
        let path: String
        let step: String
        let status: OSStatus
        var errorDescription: String? {
            let reason = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
            return "could not read the code requirement of \(path) (\(step)): \(reason)"
        }
    }

    /// Designated requirement text of the code at `url` (a bundle or a bare
    /// executable). Throws when the path is not signed or cannot be read.
    static func designated(ofCodeAt url: URL) throws -> String {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard created == errSecSuccess, let staticCode else {
            throw ReadError(path: url.path, step: "SecStaticCodeCreateWithPath", status: created)
        }
        var requirement: SecRequirement?
        let copied = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
        guard copied == errSecSuccess, let requirement else {
            throw ReadError(path: url.path, step: "SecCodeCopyDesignatedRequirement", status: copied)
        }
        var text: CFString?
        let printed = SecRequirementCopyString(requirement, [], &text)
        guard printed == errSecSuccess, let text else {
            throw ReadError(path: url.path, step: "SecRequirementCopyString", status: printed)
        }
        return text as String
    }
}
