import Foundation

// Entry point. A one-shot command-line mode is answered here, before AppKit
// or SwiftUI start, so the scripts can borrow the app's kernel-level
// identity check (see ResumeFrozenCommand) and its access control list
// reader (see AccessListsCommand), each of which ends itself when its
// lifetime is up. Anything else starts the menu bar app.
let oneShotArguments = Array(CommandLine.arguments.dropFirst())
if let output = ResumeFrozenCommand.run(oneShotArguments, endAfter: ResumeFrozenCommand.endProcess)
    ?? AccessListsCommand.run(oneShotArguments, endAfter: ResumeFrozenCommand.endProcess) {
    for line in output.lines { print(line) }
    exit(output.status)
}
InsomniaApp.main()
