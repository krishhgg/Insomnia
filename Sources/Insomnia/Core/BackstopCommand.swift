import Darwin
import Foundation

/// Launchd starts our signed executable so Login Items can attribute the
/// recovery agent to Insomnia, then we replace it with the verified script.
enum BackstopCommand {
    static let argument = "--backstop"

    static func run(_ arguments: [String], bundle: URL = Bundle.main.bundleURL) -> Int32? {
        guard arguments.first == argument else { return nil }
        guard arguments.count == 2, !arguments[1].isEmpty, bundle.pathExtension == "app" else {
            fputs("usage: Insomnia --backstop <code-requirement> (from Insomnia.app)\n", stderr)
            return 64
        }
        do {
            try CodeRequirement.verify(codeAt: bundle, satisfies: arguments[1])
        } catch {
            let reason = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
            Log.error("backstop agent: \(bundle.path) does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). \(reason)")
            return 1
        }
        let command = ["/bin/bash", Paths.backstopScript(inBundle: bundle).path]
        var argv = command.map { strdup($0) } + [nil]
        defer { for argument in argv { free(argument) } }
        return argv.withUnsafeMutableBufferPointer {
            execv("/bin/bash", $0.baseAddress!)
            perror("Insomnia backstop: exec /bin/bash")
            return 1
        }
    }
}
