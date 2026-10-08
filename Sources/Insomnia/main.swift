import Foundation

// Entry point. A one-shot command-line mode is answered here, before AppKit
// or SwiftUI start, so backstop.sh can borrow the app's kernel-level
// identity check (see ResumeFrozenCommand) and its config.json decoder (see
// AgentCutoffsCommand); each ends itself when its lifetime is up. Anything
// else starts the menu bar app.
let arguments = Array(CommandLine.arguments.dropFirst())
if let output = ResumeFrozenCommand.run(arguments, endAfter: ResumeFrozenCommand.endProcess)
    ?? AgentCutoffsCommand.run(arguments, endAfter: ResumeFrozenCommand.endProcess) {
    for line in output.lines { print(line) }
    exit(output.status)
}
InsomniaApp.main()
