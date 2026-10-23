import Foundation

// Answer both recovery commands before starting AppKit or SwiftUI. The
// backstop mode execs the verified script; resume-frozen performs the
// kernel-level process identity check with its own lifetime limit.
if let status = BackstopCommand.run(Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}

if let output = ResumeFrozenCommand.run(Array(CommandLine.arguments.dropFirst()), endAfter: ResumeFrozenCommand.endProcess) {
    for line in output.lines { print(line) }
    exit(output.status)
}
InsomniaApp.main()
