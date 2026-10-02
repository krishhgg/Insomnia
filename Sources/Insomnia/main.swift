import Foundation

// Entry point. A one-shot command-line mode is answered here, before AppKit
// or SwiftUI start, so backstop.sh can borrow the app's kernel-level
// identity check for one pid (see ResumeFrozenCommand). Anything else
// starts the menu bar app.
if let result = ResumeFrozenCommand.run(Array(CommandLine.arguments.dropFirst())) {
    print(result.word)
    exit(result.status)
}
InsomniaApp.main()
