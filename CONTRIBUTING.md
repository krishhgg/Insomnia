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
warning fails the build. Two Linux jobs run ShellCheck over `scripts/` and
`.github/scripts/` and actionlint plus zizmor over `.github/workflows`. Greptile reviews every
push to a pull request with the rules in `.greptile/`; it reads that folder
from the pull request's branch.

The ShellCheck job, with the ShellCheck version it pins, also lists every
finding that a directive hides in `scripts/`, and fails unless the list
matches `.github/shellcheck-hidden.txt`. A directive covers the next
command, so a `{` added after an existing one and a `}` at the end would
put the rest of the script under it without touching the directive. If
your change hides something new on purpose, copy the list CI prints into
that file. The file counts as config, so the owner OKs the change. The
check also fails if a `# shellcheck` stands outside a comment, in a
string, a here-document or backticks, since it could not then remove the
directives without changing how the script parses.

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
in the release validation record. New behavior that needs a real-Mac check
adds an item to the "Real-Mac checks before a release" list in
docs/releasing.md. Never stress or heat a machine in a bag. A pull request
also needs its own real-Mac report before it merges; see "Real-Mac evidence"
below.

The app icon is the menu bar's open eye on a charcoal tile.
[AppIconArtwork](Sources/Insomnia/UI/AppIconArtwork.swift) draws it from the
same [vector geometry](Sources/Insomnia/UI/EyeMarkGeometry.swift) as the menu
bar's closed eye, which opens while a session runs. After changing the
artwork, run `./scripts/generate-app-icon.sh`. It regenerates the packaged PNG
and ICNS assets and the README's SVG offline, with Xcode's swiftc and
iconutil.

## How a pull request merges

A pull request merges into main only when every check below passes at its
head commit, the newest commit on its branch. GitHub enforces this, for the
owner too. A check belongs to one commit, so any push to the branch,
including a maintainer's fix or a merge of main, starts every check over.

| Check | Passes when |
|---|---|
| Swift test and release build (macOS 26) and (macOS 27) | `swift test` and the release build pass on both hosted macOS versions |
| ShellCheck scripts, Lint workflows | ShellCheck, actionlint and zizmor find nothing |
| merge-gate/greptile | Greptile reviewed the head and scored it 5/5 |
| merge-gate/accepted | the owner added the `accepted` label |
| merge-gate/evidence | the maintainer checked a real-Mac report for the head, or the pull request only changes paths listed under "Real-Mac evidence" |
| merge-gate/config | the pull request leaves the config that steers checks alone (listed below), the owner wrote it, or the owner OK'd those changes at the head |
| merge-gate/codex | the maintainer's Codex review of the head has nothing open |

Every review conversation must be resolved too, and the branch must merge
into main without conflicts. Each CI job must also have tested the pull
request merged with the current main. When main moves, the maintainer
reruns CI, which leaves your head commit and your report as they are. The
[merge gate workflow](.github/workflows/merge-gate.yml) posts the
merge-gate statuses it can decide from GitHub's data and marks the rest
pending with the reason; [merge-gate.sh](.github/scripts/merge-gate.sh)
describes each one.

`accepted` is the owner's decision that Insomnia should have the change at
all. Before you build a new feature or change a default, open an issue so
that is settled first.

`config` exists because some files can switch off a check: a pull request
from a fork runs the workflow files on its own branch, and Greptile reads
its rules from the branch it reviews. So the gate passes a change without
the owner's OK only when every file it touches is one of these kinds:

- Swift files under `Sources/`, and `.swift`, `.h` or `.c` files under
  `Tests/`
- `.md`, `.html` or `.svg` files under `docs/`, and `.md` files under
  `skills/`
- `.sh` or `.swift` files directly in `scripts/`, except
  `scripts/check-lid-simulation-gate.sh`, which CI runs
- `.plist` files under `Resources/`
- `README.md` and `LICENSE` (`SECURITY.md` and this file set the project's
  policy, and Greptile reads them as guidance for every review)

Even there, some files count as config:

- a name starting with a dot, such as `.greptile/` or `.shellcheckrc`
- an `AGENTS.md`, `AGENTS.override.md`, `CLAUDE.md`, `CLAUDE.local.md` or
  `GEMINI.md`, which review agents follow
- a file whose diff adds a ShellCheck directive (`# shellcheck ...`) or a
  Swift `@diagnose` or `@warn` attribute in any spelling, since those switch
  off warnings from inside the file
- a file GitHub shows no diff for, because it is too big or binary, unless
  it was deleted. No reviewer can read it, one NUL byte makes a script
  binary, and a script could source it.
- a symlink or a submodule. CI follows a symlink, so `scripts/x.sh`
  pointing at an image would be linted with whatever the image holds.

Anything else, such as `.github/`, `Package.swift`, an image or a new kind
of file, waits for the owner. The kinds in the first list pass only in the
case shown there, so `scripts/backstop.SH` counts as config: CI's
`scripts/*.sh` checks would skip it, but a Mac still opens it as
`scripts/backstop.sh`. The Mac runners check out to a disk that treats `S`,
`s` and look-alikes such as `ſ` as one letter, so the names that count
match in any case, and any name with a non-ASCII character counts.

CI runs your code, so a test could make a check pass without doing its
work. The release build and the lid check run before the tests for that
reason, and the Codex review looks for tests and sources that skip, weaken
or tamper with checks.

### Real-Mac evidence

A pull request that changes anything outside `docs/`, `Tests/`, `.github/`,
`.greptile/`, README.md, CONTRIBUTING.md, SECURITY.md, LICENSE and
.gitignore needs a report from your own Mac for its head commit. Post it as
a comment after your last push. If you push again, post a new one. For the
owner's own pull requests, the owner posts it.

- **Build.** A clean checkout of the head commit, with no other pull
  requests applied, installed with `./scripts/install.sh`. Post
  `git rev-parse HEAD` and `git status --short`, which should print nothing.
- **Mac.** Post `sw_vers`, `sysctl -n hw.model` and
  `sysctl -n machdep.cpu.brand_string`.
- **Checks.** Every item in "Real-Mac checks before a release" in
  [docs/releasing.md](docs/releasing.md) that your change can affect,
  including any item it adds. For each one, post the steps you ran with
  times, pass or fail, and the raw output that shows it:
  - the lines of `~/Library/Logs/Insomnia/insomnia.log` for that run;
  - pmset samples from a sampler you start before the check and leave
    running:
    ```sh
    while :; do date '+%T'; pmset -g | grep SleepDisabled; pmset -g custom | sed -n '/Battery Power/,/AC Power/p' | grep -E 'powermode|lowpowermode'; sleep 5; done | tee -a ~/insomnia-samples.txt
    ```
  - `pmset -g log | grep -E ' (Sleep|Wake|DarkWake) '` for that time
    window, which shows whether the Mac slept;
  - any other reading the item names.
- **Not run.** List anything you could not run, and why.

Put long logs in a gist and link it. Run the checks while you are with the
Mac, on a stable, ventilated surface, never in a bag, and with no unsaved
work open. The maintainer checks that the report covers the head and every
affected item, then marks merge-gate/evidence.
