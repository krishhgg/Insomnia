import Foundation

// Entry point. A one-shot command-line mode is answered here, before AppKit
// or SwiftUI start, so backstop.sh can borrow the app's kernel-level
// identity check (see ResumeFrozenCommand), which ends itself when its
// lifetime is up. Anything else starts the menu bar app.
if let output = ResumeFrozenCommand.run(Array(CommandLine.arguments.dropFirst()), endAfter: ResumeFrozenCommand.endProcess) {
    for line in output.lines { print(line) }
    exit(output.status)
}
if let output = AgentActivityCommand.run(Array(CommandLine.arguments.dropFirst())) {
    if !output.text.isEmpty {
        if output.status == 0 { print(output.text) }
        else { FileHandle.standardError.write(Data((output.text + "\n").utf8)) }
    }
    exit(output.status)
}
InsomniaApp.main()
