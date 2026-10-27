import Foundation

// Entry point. One-shot command-line modes are answered here, before AppKit
// or SwiftUI start: the recovery agent's backstop mode execs the verified
// script (see BackstopCommand), backstop.sh borrows the app's kernel-level
// identity check (see ResumeFrozenCommand), which ends itself when its
// lifetime is up, and scripts drive the running app's session (see
// SessionCommandLine). Anything else starts the menu bar app.
if let status = BackstopCommand.run(Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}

if let output = ResumeFrozenCommand.run(Array(CommandLine.arguments.dropFirst()), endAfter: ResumeFrozenCommand.endProcess) {
    for line in output.lines { print(line) }
    exit(output.status)
}
if let output = SessionCommandLine.run(Array(CommandLine.arguments.dropFirst())) {
    for line in output.lines { print(line) }
    exit(output.status)
}
InsomniaApp.main()
