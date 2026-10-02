import Foundation

// Entry point. A one-shot command-line mode is answered here, before AppKit
// or SwiftUI start, so backstop.sh can borrow the app's kernel-level
// identity check (see ResumeFrozenCommand). Anything else starts the menu
// bar app.
if let output = ResumeFrozenCommand.run(Array(CommandLine.arguments.dropFirst())) {
    for line in output.lines { print(line) }
    exit(output.status)
}
InsomniaApp.main()
