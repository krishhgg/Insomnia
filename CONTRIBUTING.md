# Contributing

Insomnia is a native Swift macOS app. Build and run the Swift test suite on
macOS 26 with an Xcode toolchain that supports the package's Swift 6.2 tools
version. Pull requests should include regression tests for changed behavior
and pass the build, test, and shell-script checks.

CI runs on every pull request and push to main. The macOS job parses
`scripts/*.sh` with `/bin/bash -n` under the system bash 3.2 and greps them
for bash 4 builtins and expansions (`mapfile`, `declare -A`, `${x,,}`),
because the LaunchAgent, install.sh and uninstall.sh run under 3.2 and
ShellCheck on Linux does not catch those. It then runs `swift test` and
builds the release with `-Xswiftc -warnings-as-errors`, so a compiler
warning fails the build. Two Linux jobs run ShellCheck over the scripts and
actionlint plus zizmor over `.github/workflows`. Greptile reviews every
push to a pull request with the rules in `.greptile/`; it reads that folder
from the pull request's branch.

The tmux integration cases require tmux at one of the executable paths probed
by the app. CI installs it explicitly; when checking a local run, inspect the
skip count so missing tmux is not mistaken for integration coverage. Tests
use private servers, not a contributor's existing panes.

Use injected system dependencies and temporary journals for automated tests.
The test bundle links the InsomniaTestHome target (Tests/InsomniaTestHome),
whose constructor points `INSOMNIA_HOME` at a throwaway directory when the
bundle loads, before XCTest runs anything and whatever `--filter` is used,
so no test writes to the real ~/Library/Logs or ~/Library/Application
Support. TestIsolationTests fails if INSOMNIA_HOME is unset or missing, or
if any path the app resolves, such as the log a default-argument line goes
to, falls outside it or inside the real ~/Library.
Do not execute installation, uninstallation, power-setting changes, process
freezing, or hotspot switching against a contributor's working machine as part
of the test suite. Never embed credentials or personal SSIDs in fixtures or logs.

For lifecycle changes, test suspension at asynchronous boundaries, shutdown
during in-flight work, failed restoration, persistence failures, and recovery
after interruption. Assert observable settings and journal consistency, not
only that a mock method was called.

Greptile comments and passing CI provide review evidence, not a safety
certification. Real-machine validation requires a supervised, separately
approved run on a ventilated surface with recoverable work. Record the exact
revision, macOS/hardware versions, observed result, and remaining limitations
in the release validation record. Never stress or heat a machine in a bag.
