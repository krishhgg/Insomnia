#!/usr/bin/env bash
# Tests for merge-gate.sh. CI runs them with bash 5 on Linux and with macOS
# /bin/bash 3.2, and merge-gate.sh runs under the same bash as this file.
# merge-gate-fake-gh.sh stands in for gh: each test writes the API responses
# it needs as JSON files and reads back the statuses the script posted, so
# nothing here reads or writes GitHub. Needs jq.
#
# Usage: bash .github/scripts/merge-gate-test.sh [test name without test_]...

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
command -v jq >/dev/null || {
  echo "merge-gate-test: needs jq" >&2
  exit 2
}

REPO=krishhgg/Insomnia
OWNER=krishhgg
BOT='github-actions[bot]'
HEAD_SHA=1111111111111111111111111111111111111111
MAIN_SHA=2222222222222222222222222222222222222222
OLD_SHA=3333333333333333333333333333333333333333
CI_CHECKS='["Swift test and release build (macOS 26)", "Swift test and release build (macOS 27)",
  "ShellCheck scripts", "Lint workflows"]'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
ln -s "$here/merge-gate-fake-gh.sh" "$tmp/bin/gh"

current='' dir='' out='' login=$BOT actions=true failed=no

fail() {
  echo "FAIL $current: $*"
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
  failed=yes
}

# run <exit status> <merge-gate.sh arguments>...: runs the script against
# the fake gh as $login, with GITHUB_ACTIONS=$actions. Its stdout and stderr
# land in $out; $dir/posts and $dir/calls start empty for each run.
run() {
  local want=$1 got=0
  shift
  : >"$dir/posts"
  : >"$dir/calls"
  out=$(PATH="$tmp/bin:$PATH" FAKE_GH_DIR=$dir FAKE_GH_LOGIN=$login GH_REPO=$REPO \
    GH_HOST=merge-gate-test.invalid GH_TOKEN=none GITHUB_ACTIONS=$actions DRY_RUN='' \
    "$BASH" "$here/merge-gate.sh" "$@" 2>&1) || got=$?
  if [ "$got" != "$want" ]; then
    fail "merge-gate.sh $* exited $got, not $want"
  fi
}

says() {
  case $out in
    *"$1"*) ;;
    *) fail "the output lacks: $1" ;;
  esac
}

# gate <gate> <state> [text]: the newest merge-gate/<gate> status on the head
# has this state, and its description holds the text.
gate() {
  local state description
  state=$(newest "$1" state)
  description=$(newest "$1" description)
  if [ "$state" != "$2" ]; then
    fail "merge-gate/$1 is $state ($description), not $2"
  fi
  case $description in
    *"${3:-}"*) ;;
    *) fail "merge-gate/$1 says: $description; wanted: $3" ;;
  esac
}

# newest <gate> <field>: that field of the newest merge-gate/<gate> status on
# the head, or none.
newest() {
  cat "$dir/commits_${HEAD_SHA}_statuses".*json | jq -rs --arg c "merge-gate/$1" --arg f "$2" \
    '[.[][] | select(.context == $c)] | max_by(.id) | if . == null then "none" else (.[$f] // "none") end'
}

# posts [gate]: how many statuses the last run posted, for one gate or all.
posts() {
  awk -F '\t' -v c="merge-gate/${1:-}" '$3 == c || c == "merge-gate/"' "$dir/posts" | wc -l | tr -d ' '
}

# calls <lines>: the gh pr and gh workflow commands the last run gave, one
# per line.
calls() {
  local got
  got=$(cat "$dir/calls")
  if [ "$got" != "$1" ]; then
    fail "gh calls: ${got:-none}; wanted: ${1:-none}"
  fi
}

# json <key>: stdin becomes the response for <key>; see merge-gate-fake-gh.sh.
json() {
  cat >"$dir/$1.json"
}

# change <key> <jq filter>: edits a response.
change() {
  jq "$2" "$dir/$1.json" >"$dir/$1.json.new"
  mv "$dir/$1.json.new" "$dir/$1.json"
}

# seed <login> <gate> <state> <description> [url]: a status someone posted on
# the head before the run under test.
seed() {
  other_status "$1" "merge-gate/$2" "$3" "$4" "${5:-}"
}

# other_status <login> <context> <state> [description] [url]: a status with
# any name someone posted on the head.
other_status() {
  FAKE_GH_DIR=$dir FAKE_GH_LOGIN=$1 GH_REPO=$REPO "$tmp/bin/gh" api -X POST "repos/$REPO/statuses/$HEAD_SHA" \
    -f state="$3" -f context="$2" -f description="${4:-}" -f target_url="${5:-}" >/dev/null
}

# later <key> <command>...: what the command makes of <key>'s response
# answers from the second read on; the first read gets the current one.
later() {
  local key=$1
  shift
  cp "$dir/$key.json" "$dir/$key.now"
  "$@"
  mv "$dir/$key.json" "$dir/$key.then.json"
  mv "$dir/$key.now" "$dir/$key.json"
}

# pr_json <author> <labels> [draft] [mergeable] [state]
pr_json() {
  jq -n --arg author "$1" --argjson labels "$2" --argjson draft "${3:-false}" \
    --argjson mergeable "${4:-true}" --arg state "${5:-open}" --arg head "$HEAD_SHA" \
    '{number: 5, state: $state, draft: $draft, mergeable: $mergeable, base: {ref: "main"},
      head: {sha: $head}, user: {login: $author}, labels: $labels}' | json pulls_5
}

# greptile_body <score> <reviewed sha>: Greptile's block as it writes it.
greptile_body() {
  printf '<h3>Greptile Summary</h3>\n\n<!-- greptile_confidence_score:%s -->\n\n' "$1"
  printf '<sub>Last reviewed commit: ["Gate"](https://github.com/krishhgg/insomnia/commit/%s)</sub>\n' "$2"
}

# edit <time> <editor> <description>: one description edit as GraphQL lists
# it; the diff is the whole description after the edit.
edit() {
  jq -n --arg t "2026-10-12T$1Z" --arg e "$2" --arg d "$3" '{editedAt: $t, editor: {login: $e}, diff: $d}'
}

# edits <file> <true|false: another page follows> <edit>...: one page of
# description edits.
edits() {
  local file=$1 more=$2
  shift 2
  printf '%s\n' "$@" | jq -s --argjson more "$more" '{data: {repository: {pullRequest: {userContentEdits: {nodes: .,
    pageInfo: {hasNextPage: $more, endCursor: (if $more then "next" else null end)}}}}}}' >"$dir/$file.json"
}

# greptile <score> <reviewed sha>: Greptile's only edit.
greptile() {
  edits graphql-edits false "$(edit 10:00:00 greptile-apps "Fixes the gate.
$(greptile_body "$1" "$2")")"
}

# label_events <[[event, login], ...]>: who added and removed "accepted".
label_events() {
  jq -n --argjson e "$1" '[{id: 1, event: "committed"}]
    + [$e | to_entries[] | {id: (.key + 2), event: .value[0], actor: {login: .value[1]}, label: {name: "accepted"}}]' |
    json issues_5_events
}

# changed <file>...: the files the head changes against main.
changed() {
  printf '%s\n' "$@" | jq -R . |
    jq -s '{files: map({filename: ., status: "modified", changes: 2, patch: "@@ -1 +1 @@\n-old\n+new"})}' |
    json "compare_main...$HEAD_SHA"
}

# diff_of <file> <status> <changes> [patch]: a comparison of one file, with
# no patch if none is given, as GitHub sends for a file too big to show.
diff_of() {
  local has=false
  [ $# -lt 4 ] || has=true
  jq -n --arg f "$1" --arg s "$2" --argjson c "$3" --arg p "${4-}" --argjson has "$has" \
    '{files: [{filename: $f, status: $s, changes: $c} + (if $has then {patch: $p} else {} end)]}' |
    json "compare_main...$HEAD_SHA"
}

# head_tree <entries> [truncated]: the head's tree as GitHub lists it,
# with only the entries given, such as [{"path": "x", "mode": "120000"}].
head_tree() {
  jq -n --argjson t "$1" --argjson cut "${2:-false}" '{truncated: $cut, tree: $t}' | json "git_trees_$HEAD_SHA"
}

# ci_runs <main sha>: the four CI jobs, ids 11 to 14, passed on the head,
# each with a Tested merge note naming that main.
ci_runs() {
  local id
  jq -n --argjson names "$CI_CHECKS" '{check_runs: [$names | to_entries[]
    | {id: (.key + 11), name: .value, status: "completed", conclusion: "success", app: {id: 15368}}]}' |
    json "commits_${HEAD_SHA}_check-runs"
  for id in 11 12 13 14; do
    note "$id" "main $1, pull request head $HEAD_SHA"
  done
}

# note <check run id> [message]...: the run's annotations: a warning, then
# one Tested merge note per message.
note() {
  local id=$1
  shift
  {
    echo '{"title": "Deprecation", "message": "a warning", "annotation_level": "warning"}'
    if [ $# -gt 0 ]; then
      printf '%s\n' "$@" | jq -R '{title: "Tested merge", message: ., annotation_level: "notice"}'
    fi
  } | jq -s . | json "check-runs_${id}_annotations"
}

# rules [ruleset id] [context to leave out] [app id for the CI checks]: the
# rules on main. Ruleset 1 is one nobody can bypass; ruleset 2 is the
# owner's, which they bypass with --admin. "-" pins no app.
rules() {
  jq -n --argjson names "$CI_CHECKS" --argjson rid "${1:-1}" --arg drop "${2:-}" --arg pin "${3:-15368}" '[
    {type: "pull_request", ruleset_id: 1, parameters: {required_review_thread_resolution: true}},
    {type: "update", ruleset_id: 2, parameters: {}},
    {type: "required_status_checks", ruleset_id: $rid, parameters: {required_status_checks:
      ([$names[] | {context: ., integration_id: ($pin | tonumber? // null)}]
        + (["greptile", "accepted", "evidence", "config", "codex"] | map({context: "merge-gate/\(.)"}))
        | map(select(.context != $drop)))}}]' | json rules_branches_main
  echo '{"id": 1, "current_user_can_bypass": "never"}' | json rulesets_1
  echo '{"id": 2, "current_user_can_bypass": "pull_requests_only"}' | json rulesets_2
}

# threads <file> <true|false: another page follows> <[isResolved, ...]>: one
# page of review threads.
threads() {
  jq -n --argjson more "$2" --argjson r "$3" '{data: {repository: {pullRequest: {reviewThreads: {
    nodes: [$r[] | {isResolved: .}],
    pageInfo: {hasNextPage: $more, endCursor: (if $more then "next" else null end)}}}}}}' >"$dir/$1.json"
}

# Pull request #5 from "someone" changes a doc. The owner added the
# accepted label, Greptile scored the head 5/5, the four CI jobs passed on
# the current main, and a ruleset nobody can bypass requires everything.
baseline() {
  echo '[]' | json "commits_${HEAD_SHA}_statuses"
  pr_json someone '[{"name": "accepted"}]'
  greptile 5 "$HEAD_SHA"
  label_events '[["labeled", "krishhgg"]]'
  changed docs/guide.md
  head_tree '[{"path": "docs", "mode": "040000"}, {"path": "docs/guide.md", "mode": "100644"}]'
  echo "{\"sha\": \"$MAIN_SHA\"}" | json commits_main
  ci_runs "$MAIN_SHA"
  rules
  threads graphql-threads false '[true]'
}

# The workflow posts the five gates, then the owner marks Codex done.
all_gates_pass() {
  run 0 evaluate 5
  login=$OWNER
  run 0 post 5 "$HEAD_SHA" codex success "nothing open"
  login=$BOT
}

test_ready_pull_request_merges() {
  run 0 evaluate 5
  gate greptile success "Greptile scored 1111111 5/5"
  gate accepted success "the owner accepted"
  gate evidence success "not needed"
  gate config success "unchanged"
  gate codex pending "Codex review of 1111111"
  login=$OWNER
  run 0 post 5 "$HEAD_SHA" codex success "nothing open" https://example.com/review
  gate codex success "nothing open"
  calls "workflow run merge-gate.yml -R $REPO -f pr=5"
  [ "$(newest codex target_url)" = https://example.com/review ] || fail "codex lost its url"
  run 0 check 5
  says "READY: #5 at $HEAD_SHA"
  run 0 merge 5
  calls "pr merge 5 -R $REPO --merge --admin --match-head-commit $HEAD_SHA"
}

test_second_evaluate_posts_nothing() {
  run 0 evaluate 5
  [ "$(posts)" = 5 ] || fail "the first run posted $(posts) statuses, not 5"
  run 0 evaluate 5
  [ "$(posts)" = 0 ] || fail "the second run posted $(posts) statuses"
}

test_owner_rejection_stands_on_their_own_config_change() {
  pr_json krishhgg '[{"name": "accepted"}]'
  changed .github/workflows/ci.yml
  seed "$OWNER" config failure "drop the new job"
  seed "$OWNER" evidence failure "the log shows no sleep"
  run 0 evaluate 5
  gate config failure "drop the new job"
  gate evidence failure "the log shows no sleep"
  [ "$(posts config)$(posts evidence)" = 00 ] || fail "posted over the owner's failures"
}

test_owner_decision_comes_back_after_an_overwrite() {
  changed Sources/Insomnia/App.swift
  seed "$OWNER" evidence success "report checked" https://example.com/report
  seed "$BOT" evidence pending "waiting for a real-Mac report"
  run 0 evaluate 5
  gate evidence success "report checked"
  [ "$(newest evidence target_url)" = https://example.com/report ] || fail "the url did not come back"
}

test_owner_pending_hands_the_gate_back() {
  changed .github/workflows/ci.yml
  seed "$OWNER" config success "fine"
  seed "$OWNER" config pending "taking it back"
  run 0 evaluate 5
  gate config pending "waiting for the owner's OK at 1111111"
}

test_owner_decision_on_a_later_page_counts() {
  changed Sources/Insomnia/App.swift
  rm "$dir/commits_${HEAD_SHA}_statuses.json"
  # GitHub lists the newest first, so 100 newer statuses push the owner's
  # OK to page 2.
  jq -n '[range(200; 100; -1) | {id: ., context: "other/check", state: "success", creator: {login: "app[bot]"}}]' |
    json "commits_${HEAD_SHA}_statuses.1"
  echo '[{"id": 50, "context": "merge-gate/evidence", "state": "success", "creator": {"login": "krishhgg"},
    "description": "report checked", "target_url": null}]' | json "commits_${HEAD_SHA}_statuses.2"
  run 0 evaluate 5
  gate evidence success "report checked"
  [ "$(posts evidence)" = 0 ] || fail "posted evidence"
}

test_fork_config_change_waits_for_the_owner() {
  changed .github/workflows/ci.yml docs/guide.md
  run 0 evaluate 5
  gate config pending "waiting for the owner's OK at 1111111"
  gate evidence success "not needed"
}

test_owner_config_change_passes() {
  pr_json krishhgg '[{"name": "accepted"}]'
  changed .github/workflows/ci.yml Package.swift
  run 0 evaluate 5
  gate config success "come from the owner"
}

test_source_change_needs_evidence() {
  changed docs/guide.md Sources/Insomnia/App.swift
  run 0 evaluate 5
  gate evidence pending "real-Mac report on 1111111"
  gate config success
}

test_moving_a_source_file_into_docs_needs_evidence() {
  echo '{"files": [{"filename": "docs/App.swift", "previous_filename": "Sources/Insomnia/App.swift",
    "status": "renamed", "changes": 0}]}' | json "compare_main...$HEAD_SHA"
  run 0 evaluate 5
  gate evidence pending
}

test_package_swift_is_config_and_needs_evidence() {
  changed Package.swift
  run 0 evaluate 5
  gate config pending
  gate evidence pending
}

test_files_that_steer_checks_are_config() {
  local f
  for f in Sources/Insomnia/Core/.greptile/config.json greptile.json docs/greptile.json Package@swift-6.swift \
    scripts/check-lid-simulation-gate.sh .shellcheckrc scripts/.shellcheckrc zizmor.yml zizmor.yaml \
    .gitignore .github/.gitignore docs/.ignore .ignore .gitattributes Sources/.gitattributes \
    package@swift-6.swift PACKAGE.SWIFT Scripts/Check-Lid-Simulation-Gate.sh .GitHub/workflows/ci.yml \
    "$(printf '\305\277cripts/check-lid-simulation-gate.sh')" "$(printf 'Package.\305\277wift')" \
    "$(printf 'docs/caf\303\251.md')" Makefile notes.txt AGENTS.md docs/AGENTS.md skills/x/claude.md \
    docs/Gemini.md Tests/InsomniaTests/.hidden.swift Tests/InsomniaTests/fixture.json Resources/run.sh \
    Sources/Insomnia/data.json scripts/lib/x.sh Plugins/Lint/plugin.swift docs/run.sh \
    CONTRIBUTING.md SECURITY.md security.md docs/CLAUDE.local.md \
    docs/AGENTS.override.md scripts/backstop.SH scripts/Install.Sh Sources/Insomnia/App.SWIFT \
    sources/Insomnia/App.swift Tests/InsomniaTests/AppTests.Swift tests/InsomniaTests/AppTests.swift \
    Docs/install.md docs/Shot.PNG Resources/AppIcon.ICNS resources/Info.plist Skills/x/SKILL.md \
    Readme.md README.MD License docs/shot.png docs/shot.jpg docs/shot.gif Resources/AppIcon.icns \
    Resources/AppIcon-1024.png; do
    changed "$f"
    run 0 evaluate 5
    [ "$(newest config state)" = pending ] || fail "$f does not count as config"
  done
}

test_only_kinds_no_check_reads_skip_config() {
  changed Sources/Insomnia/App.swift Sources/Insomnia/Package.swift Tests/InsomniaTests/AppTests.swift \
    Tests/InsomniaTestHome/include/Home.h Tests/InsomniaTestHome/Home.c docs/install.md docs/spec.md \
    docs/release-validation.md \
    docs/mockups/menubar-ux.html docs/assets/eye.svg \
    scripts/install.sh scripts/generate-app-icon.swift skills/install-insomnia/SKILL.md \
    Resources/Info.plist README.md LICENSE
  run 0 evaluate 5
  gate config success
}

test_greptile_guidance_files_are_config() {
  local f n=0
  while IFS= read -r f; do
    n=$((n + 1))
    changed "$f"
    run 0 evaluate 5
    [ "$(newest config state)" = pending ] || fail "$f, Greptile guidance in files.json, does not count as config"
  done < <(jq -r '.[] | select(has("scope") | not) | .path
    | select(. != "docs/spec.md" and . != "docs/release-validation.md")' "$here/../../.greptile/files.json")
  [ "$n" -gt 0 ] || fail "read no unscoped paths from .greptile/files.json"
}

test_an_added_shellcheck_directive_is_config() {
  local line
  for line in '# shellcheck disable=all' $'#\tshellcheck disable=all' '#   shellcheck shell=sh' \
    'true;# shellcheck disable=SC2086'; do
    diff_of scripts/backstop.sh modified 1 "$(printf '@@ -1,2 +1,3 @@\n #!/bin/bash\n+%s\n set -u' "$line")"
    run 0 evaluate 5
    [ "$(newest config state)" = pending ] || fail "\"$line\" does not count as config"
  done
}

test_a_shellcheck_directive_in_a_swift_test_is_config() {
  diff_of Tests/InsomniaTests/FakeTests.swift modified 1 $'@@ -1 +1,2 @@\n let a = 1\n+let fake = "#!/bin/sh\\n#shellcheck\tdisable=SC2086"'
  run 0 evaluate 5
  gate config pending
}

test_an_added_swift_warning_control_is_config() {
  local attr
  for attr in '@warn(DeprecatedDeclaration, as: ignored)' '@diagnose(DeprecatedDeclaration, as: ignored)' \
    "@\`diagnose\`(DeprecatedDeclaration, as: ignored)" '@ warn(DeprecatedDeclaration, as: ignored)' '@diagnose'; do
    diff_of Sources/Insomnia/App.swift modified 1 "$(printf '@@ -1 +1,2 @@\n+%s\n func f() {}' "$attr")"
    run 0 evaluate 5
    [ "$(newest config state)" = pending ] || fail "$attr does not count as config"
  done
  diff_of Sources/Insomnia/App.swift modified 1 $'@@ -1 +1 @@\n+@diagnose'
  run 0 evaluate 5
  [ "$(newest config state)" = pending ] || fail "@diagnose at the end of a diff does not count as config"
  diff_of Sources/Insomnia/App.swift modified 1 $'@@ -1 +1,2 @@\n+@warn_unqualified_access\n func f() {}'
  run 0 evaluate 5
  gate config success
}

test_a_directive_the_diff_only_keeps_or_removes_is_not_config() {
  diff_of scripts/backstop.sh modified 2 $'@@ -1,4 +1,4 @@\n # shellcheck disable=SC2086\n x=$((a+1)) # shellcheck disable=SC2004\n-# shellcheck disable=SC2034\n-echo $a\n+echo "$a"'
  run 0 evaluate 5
  gate config success
}

test_a_file_without_a_diff_is_config() {
  # Too big to show, binary (a NUL byte in a script makes it so), or
  # renamed: GitHub sends no patch for any of them.
  local spec
  for spec in 'Sources/Insomnia/Huge.swift modified 9000' 'scripts/backstop.sh modified 0' \
    'Sources/Insomnia/B.swift renamed 0' 'docs/assets/eye.svg added 0' 'scripts/x.png.sh added 0' \
    'Resources/Info.plist modified 0' 'docs/guide.md modified 0'; do
    # shellcheck disable=SC2086 # split the spec into the arguments
    diff_of $spec
    run 0 evaluate 5
    [ "$(newest config state)" = pending ] || fail "$spec without a diff does not count as config"
  done
}

test_removed_files_need_no_diff() {
  jq -n '{files: [{filename: "Sources/Insomnia/Old.swift", status: "removed", changes: 9000},
    {filename: "scripts/old.sh", status: "removed", changes: 0}]}' | json "compare_main...$HEAD_SHA"
  run 0 evaluate 5
  gate config success
}

test_a_changed_symlink_or_submodule_is_config() {
  # CI would lint the file a symlink points at, such as a binary image
  # holding a script and its ShellCheck directives.
  local mode
  for mode in 120000 160000; do
    diff_of scripts/unchecked.sh added 1 $'@@ -0,0 +1 @@\n+../docs/guide.md\n\\ No newline at end of file'
    head_tree "[{\"path\": \"scripts/unchecked.sh\", \"mode\": \"$mode\"}]"
    run 0 evaluate 5
    [ "$(newest config state)" = pending ] || fail "a changed file of mode $mode does not count as config"
  done
}

test_an_unchanged_symlink_is_not_config() {
  head_tree '[{"path": "docs/guide.md.link", "mode": "120000"}, {"path": "docs/guide.md", "mode": "100644"}]'
  run 0 evaluate 5
  gate config success
}

test_a_tree_cut_short_is_config() {
  local cut
  for cut in true null; do
    head_tree '[]' "$cut"
    run 0 evaluate 5
    [ "$(newest config state)" = pending ] || fail "a tree with truncated $cut does not count as config"
  done
}

test_a_failed_tree_read_stops_evaluate() {
  touch "$dir/git_trees_$HEAD_SHA.fail"
  run 2 evaluate 5
  says "could not evaluate #5"
  [ "$(posts)" = 0 ] || fail "posted before every read succeeded"
}

test_a_rename_to_another_case_is_config() {
  # CI's scripts/*.sh globs would skip the new name, while the Mac's
  # case-insensitive disk still opens it as scripts/backstop.sh.
  jq -n '{files: [{filename: "scripts/backstop.SH", previous_filename: "scripts/backstop.sh",
    status: "renamed", changes: 2, patch: "@@ -1 +1 @@\n-#!/bin/bash\n+#!/bin/ksh"}]}' |
    json "compare_main...$HEAD_SHA"
  run 0 evaluate 5
  gate config pending
}

test_a_line_break_in_a_name_counts_as_config() {
  diff_of "$(printf 'README.md\nSources/a.swift')" added 1 $'@@ -0,0 +1 @@\n+x'
  run 0 evaluate 5
  gate config pending
}

test_skills_need_evidence() {
  changed skills/insomnia/SKILL.md
  run 0 evaluate 5
  gate evidence pending
}

test_three_hundred_files_assume_the_worst() {
  jq -n '{files: [range(300) | {filename: "docs/page\(.).md"}]}' | json "compare_main...$HEAD_SHA"
  run 0 evaluate 5
  gate evidence pending
  gate config pending
}

test_forged_greptile_score_fails() {
  # The author wrote a block of their own before Greptile's edit, so
  # Greptile's description holds both, the forged one first.
  edits graphql-edits false "$(edit 10:00:00 greptile-apps "$(greptile_body 5 "$HEAD_SHA")
$(greptile_body 2 "$HEAD_SHA")")"
  run 0 evaluate 5
  gate greptile failure "2 Greptile scores and 2 reviewed commits"
}

test_author_edit_after_greptile_does_not_count() {
  edits graphql-edits false "$(edit 11:00:00 someone "$(greptile_body 5 "$HEAD_SHA")")" \
    "$(edit 10:00:00 greptile-apps "$(greptile_body 3 "$HEAD_SHA")")"
  run 0 evaluate 5
  gate greptile failure "Greptile scored 1111111 3/5"
}

test_greptile_score_for_an_older_commit_waits() {
  greptile 5 "$OLD_SHA"
  run 0 evaluate 5
  gate greptile pending "its summary covers 3333333"
}

test_no_greptile_review_waits() {
  edits graphql-edits false "$(edit 09:00:00 someone "My change.")"
  run 0 evaluate 5
  gate greptile pending "first review"
}

test_greptile_below_five_fails() {
  greptile 4 "$HEAD_SHA"
  run 0 evaluate 5
  gate greptile failure "4/5; the gate needs 5/5"
}

test_newest_greptile_edit_wins_across_pages() {
  # GraphQL lists the newest edit first, so the last row read is the oldest.
  rm "$dir/graphql-edits.json"
  edits graphql-edits.1 true "$(edit 12:00:00 greptile-apps "$(greptile_body 5 "$HEAD_SHA")")"
  edits graphql-edits.2 false "$(edit 09:00:00 greptile-apps "$(greptile_body 2 "$OLD_SHA")")"
  run 0 evaluate 5
  gate greptile success
}

test_label_from_someone_else_waits() {
  label_events '[["labeled", "krishhgg"], ["unlabeled", "someone"], ["labeled", "someone"]]'
  run 0 evaluate 5
  gate accepted pending "not added by the owner (labeled someone)"
}

test_no_label_waits() {
  pr_json someone '[]'
  run 0 evaluate 5
  gate accepted pending "waiting for the owner's accepted label"
}

test_failed_read_stops_evaluate() {
  touch "$dir/compare_main...$HEAD_SHA.fail"
  run 2 evaluate 5
  says "could not evaluate #5"
  [ "$(posts)" = 0 ] || fail "posted before every read succeeded"
}

test_closed_pull_request_is_skipped() {
  pr_json someone '[]' false true closed
  run 0 evaluate 5
  says "closed into main, skipped"
  [ "$(posts)" = 0 ] || fail "posted on a closed pull request"
}

test_evaluate_posts_only_from_the_workflow() {
  actions=''
  run 2 evaluate 5
  says "only the merge gate workflow posts these"
  [ "$(posts)" = 0 ] || fail "posted outside the workflow"
}

test_post_refuses_another_head_and_other_gates() {
  login=$OWNER
  run 2 post 5 "$OLD_SHA" codex success "fine"
  says "#5's head is $HEAD_SHA, not $OLD_SHA"
  run 2 post 5 "$HEAD_SHA" greptile success "fine"
  says "not greptile"
  run 2 post 5 1111111 codex success "fine"
  says "not a full commit sha"
  [ "$(posts)" = 0 ] || fail "posted"
}

test_list() {
  echo '[{"number": 5}, {"number": 9}]' | json pulls
  run 0 list all
  [ "$out" = "[5,9]" ] || fail "list all printed $out"
  run 0 list 5 12
  [ "$out" = "[5,12]" ] || fail "list 5 12 printed $out"
  run 2 list 5x
}

test_check_refuses_ci_on_an_older_main() {
  all_gates_pass
  ci_runs "$OLD_SHA"
  run 1 check 5
  says "success on main 3333333, but main is now 2222222; run:"
  says "rerun 5"
  says "NOT READY: #5 at 1111111, 4 failing"
}

test_check_refuses_a_newer_run_still_going() {
  all_gates_pass
  mv "$dir/commits_${HEAD_SHA}_check-runs.json" "$dir/commits_${HEAD_SHA}_check-runs.1.json"
  echo '{"check_runs": [{"id": 21, "name": "Swift test and release build (macOS 26)", "status": "in_progress",
    "conclusion": null, "app": {"id": 15368}}]}' | json "commits_${HEAD_SHA}_check-runs.2"
  run 1 check 5
  says "in_progress, none"
  says "1 failing"
}

test_check_needs_exactly_one_tested_merge_note() {
  all_gates_pass
  note 12 "main $MAIN_SHA, pull request head $HEAD_SHA" "main $MAIN_SHA, pull request head $HEAD_SHA"
  run 1 check 5
  says "2 Tested merge notes, not 1"
  note 12
  run 1 check 5
  says "0 Tested merge notes, not 1"
  note 12 "main $MAIN_SHA, pull request head $OLD_SHA"
  run 1 check 5
  says "its note names head 3333333"
}

test_check_ignores_runs_from_other_apps() {
  all_gates_pass
  change "commits_${HEAD_SHA}_check-runs" '(.check_runs[] | select(.id == 13)).conclusion = "failure"
    | .check_runs += [{id: 30, name: "ShellCheck scripts", status: "completed", conclusion: "success", app: {id: 999}}]'
  run 1 check 5
  says "completed, failure"
}

test_check_refuses_gate_success_from_anyone_else() {
  all_gates_pass
  seed 'app[bot]' accepted success "looks good"
  run 1 check 5
  says "success from app[bot], who is neither the workflow nor the owner"
}

test_check_reads_threads_on_every_page() {
  all_gates_pass
  rm "$dir/graphql-threads.json"
  threads graphql-threads.1 true "$(jq -n '[range(100) | true]')"
  threads graphql-threads.2 false '[true, false]'
  run 1 check 5
  says "1 open"
}

test_check_refuses_a_conflict_or_draft() {
  all_gates_pass
  pr_json someone '[{"name": "accepted"}]' true null
  run 1 check 5
  says "the pull request is a draft"
  says "GitHub is still working it out"
}

test_check_needs_rules_nobody_can_bypass() {
  all_gates_pass
  rules 2
  run 1 check 5
  says "not required by a ruleset you cannot bypass: Swift test and release build (macOS 26),"
  rules 1 merge-gate/codex
  run 1 check 5
  says "cannot bypass: merge-gate/codex;"
  rules 1 '' -
  run 1 check 5
  says "not pinned to GitHub Actions: Swift test and release build (macOS 26),"
  rules
  change rules_branches_main '(.[] | select(.type == "pull_request")).parameters.required_review_thread_resolution = false'
  run 1 check 5
  says "resolved conversations required: false"
}

test_check_evaluates_extra_required_checks() {
  all_gates_pass
  change rules_branches_main '(.[] | select(.type == "required_status_checks")).parameters.required_status_checks
    += [{context: "mac-mini/macOS 15", integration_id: null}]'
  other_status "$OWNER" "mac-mini/macOS 15" failure
  run 1 check 5
  says "FAIL  mac-mini/macOS 15"
  other_status "$OWNER" "mac-mini/macOS 15" success
  run 0 check 5
  says "pass  mac-mini/macOS 15"
}

test_check_sees_an_owner_failure_posted_during_a_run() {
  # The workflow read the statuses, the owner then posted a failure, and the
  # workflow's automatic success landed on top of it.
  all_gates_pass
  seed "$OWNER" evidence failure "the log shows no sleep"
  seed "$BOT" evidence success "not needed: only docs, tests and repo tooling change"
  run 1 check 5
  says "posted success, but it is now failure: the log shows no sleep"
}

test_check_sees_a_label_removed_before_the_workflow_runs() {
  all_gates_pass
  pr_json someone '[]'
  label_events '[["labeled", "krishhgg"], ["unlabeled", "krishhgg"]]'
  run 1 check 5
  says "posted success, but it is now pending: waiting for the owner's accepted label"
}

test_check_sees_a_lower_greptile_score_before_the_workflow_runs() {
  all_gates_pass
  greptile 3 "$HEAD_SHA"
  run 1 check 5
  says "posted success, but it is now failure: Greptile scored 1111111 3/5"
}

test_check_says_when_the_workflow_is_behind() {
  pr_json someone '[]'
  all_gates_pass
  pr_json someone '[{"name": "accepted"}]'
  run 1 check 5
  says "pending, but it is now success; run: gh workflow run merge-gate.yml -R $REPO -f pr=5"
}

test_check_reports_a_failing_gate_once() {
  # Codex stays pending. The last read only runs if every row passed, so
  # the gate does not fail a second time as a change.
  run 0 evaluate 5
  run 1 check 5
  says "FAIL  merge-gate/codex"
  says "NOT READY: #5 at 1111111, 1 failing"
}

test_check_sees_main_move_during_the_check() {
  all_gates_pass
  echo '{"sha": "4444444444444444444444444444444444444444"}' | json commits_main.then
  run 1 check 5
  says "FAIL  nothing changed during this check"
  says "main moved from 2222222 to 4444444; run check again"
  says "1 failing"
}

test_check_sees_an_owner_failure_posted_during_the_check() {
  all_gates_pass
  later "commits_${HEAD_SHA}_statuses" seed "$OWNER" evidence failure "the log shows no sleep"
  run 1 check 5
  says "merge-gate/evidence is now failure; run check again"
  says "1 failing"
}

test_check_sees_a_stranger_post_during_the_check() {
  all_gates_pass
  later "commits_${HEAD_SHA}_statuses" seed stranger codex success "looks fine"
  run 1 check 5
  says "merge-gate/codex is now a success from stranger; run check again"
}

test_check_sees_the_head_move_during_the_check() {
  all_gates_pass
  later pulls_5 change pulls_5 '.head.sha = "5555555555555555555555555555555555555555"'
  run 1 check 5
  says "the head moved to 5555555; run check again"
}

test_check_sees_the_pull_request_change_during_the_check() {
  all_gates_pass
  later pulls_5 change pulls_5 '.draft = true'
  run 1 check 5
  says "the pull request is now a draft; run check again"
  pr_json someone '[{"name": "accepted"}]'
  later pulls_5 change pulls_5 '.base.ref = "release"'
  run 1 check 5
  says "the pull request is now open into release; run check again"
  pr_json someone '[{"name": "accepted"}]'
  later pulls_5 change pulls_5 '.mergeable = null'
  run 1 check 5
  says "GitHub now gives mergeable as null; run check again"
}

test_an_owner_failure_in_capitals_counts() {
  # GitHub treats MERGE-GATE/Evidence as merge-gate/evidence.
  changed Sources/Insomnia/App.swift
  seed "$OWNER" evidence success "report checked"
  seed "$BOT" evidence pending "waiting for a real-Mac report"
  other_status "$OWNER" MERGE-GATE/Evidence failure "the log shows no sleep"
  run 0 evaluate 5
  [ "$(posts evidence)" = 0 ] || fail "posted evidence $(posts evidence) times over the owner's failure"
  run 1 check 5
  says "FAIL  merge-gate/evidence                      failure: the log shows no sleep [krishhgg]"
}

test_check_counts_a_ci_status_in_lower_case() {
  all_gates_pass
  other_status "$BOT" "shellcheck scripts" failure
  run 1 check 5
  says "FAIL  ShellCheck scripts (app 15368)"
  says "as the ruleset counts it: status: failure"
}

test_check_runs_match_in_any_case_but_count_only_by_name() {
  all_gates_pass
  change rules_branches_main '(.[] | select(.type == "required_status_checks")).parameters.required_status_checks
    += [{context: "mac-mini", integration_id: null}]'
  change "commits_${HEAD_SHA}_check-runs" '.check_runs += [
    {id: 40, name: "mac-mini", status: "completed", conclusion: "success", app: {id: 555}},
    {id: 41, name: "Mac-Mini", status: "completed", conclusion: "failure", app: {id: 555}}]'
  run 1 check 5
  says "FAIL  mac-mini                                 check run from app 555: completed, failure"
  change "commits_${HEAD_SHA}_check-runs" '.check_runs |= map(select(.id != 40) | if .id == 41 then .conclusion = "success" else . end)'
  run 1 check 5
  says "FAIL  mac-mini                                 no check run or status"
  change "commits_${HEAD_SHA}_check-runs" '.check_runs = [.check_runs[] | select(.name != "Mac-Mini")] + [
    {id: 42, name: "mac-mini", status: "completed", conclusion: "success", app: {id: 555}},
    {id: 43, name: "MAC-MINI", status: "completed", conclusion: "failure", app: {id: 556}}]'
  run 1 check 5
  says "FAIL  mac-mini                                 check run from app 556: completed, failure"
  # A newer passing run under another spelling does not hide the failure.
  change "commits_${HEAD_SHA}_check-runs" '.check_runs = [.check_runs[] | select(.id < 40)] + [
    {id: 44, name: "mac-mini", status: "completed", conclusion: "failure", app: {id: 555}},
    {id: 45, name: "Mac-Mini", status: "completed", conclusion: "success", app: {id: 555}}]'
  run 1 check 5
  says "FAIL  mac-mini                                 check run from app 555: completed, failure"
}

test_check_fails_if_any_status_with_the_name_fails() {
  # GitHub's combined status should list a context once in any case; if it
  # lists two, a failure in either counts.
  all_gates_pass
  change rules_branches_main '(.[] | select(.type == "required_status_checks")).parameters.required_status_checks
    += [{context: "mac-mini", integration_id: null}]'
  echo '{"statuses": [{"context": "Mac-Mini", "state": "failure"}, {"context": "mac-mini", "state": "success"}]}' |
    json "commits_${HEAD_SHA}_status"
  run 1 check 5
  says "FAIL  mac-mini                                 status: failure"
}

test_merge_stops_if_the_label_goes_during_the_check() {
  all_gates_pass
  later pulls_5 pr_json someone '[]'
  later issues_5_events label_events '[["labeled", "krishhgg"], ["unlabeled", "krishhgg"]]'
  run 2 merge 5
  says "merge-gate/accepted now works out to pending: waiting for the owner's accepted label; run check again"
  says "NOT READY: #5 at 1111111, 1 failing"
  calls ""
}

test_check_counts_a_gate_pinned_to_an_app() {
  all_gates_pass
  change rules_branches_main '(.[] | select(.type == "required_status_checks")).parameters.required_status_checks
    |= map(if .context == "merge-gate/codex" then .integration_id = 777 else . end)'
  run 1 check 5
  says "FAIL  merge-gate/codex (app 777)"
  says "no check run from app 777"
}

test_check_counts_a_ci_name_required_from_another_app() {
  all_gates_pass
  change rules_branches_main '(.[] | select(.type == "required_status_checks")).parameters.required_status_checks
    += [{context: "ShellCheck scripts", integration_id: 999}]'
  run 1 check 5
  says "FAIL  ShellCheck scripts (app 999)"
}

test_check_counts_a_failing_status_beside_a_passing_run() {
  all_gates_pass
  change rules_branches_main '(.[] | select(.type == "required_status_checks")).parameters.required_status_checks
    += [{context: "mac-mini", integration_id: null}]'
  change "commits_${HEAD_SHA}_check-runs" '.check_runs += [{id: 40, name: "mac-mini", status: "completed",
    conclusion: "success", app: {id: 555}}]'
  other_status "$OWNER" mac-mini failure
  run 1 check 5
  says "FAIL  mac-mini"
  says "status: failure"
}

test_check_counts_a_failing_status_named_like_a_pinned_check() {
  all_gates_pass
  other_status "$BOT" "ShellCheck scripts" failure
  run 1 check 5
  says "FAIL  ShellCheck scripts (app 15368)"
  says "as the ruleset counts it: status: failure"
  says "1 failing"
  change rules_branches_main '(.[] | select(.type == "required_status_checks")).parameters.required_status_checks
    += [{context: "mac-mini", integration_id: 555}]'
  change "commits_${HEAD_SHA}_check-runs" '.check_runs += [{id: 40, name: "mac-mini", status: "completed",
    conclusion: "success", app: {id: 555}}]'
  other_status "$OWNER" mac-mini failure
  run 1 check 5
  says "FAIL  mac-mini (app 555)"
  says "2 failing"
}

test_an_owner_description_is_restored_once() {
  # A backslash and a tab used to come back escaped, so every run posted
  # the owner's decision again.
  changed Sources/Insomnia/App.swift
  seed "$OWNER" evidence success 'report\checked	on 26.1'
  seed "$BOT" evidence pending "waiting for a real-Mac report"
  run 0 evaluate 5
  gate evidence success 'report\checked on 26.1'
  [ "$(posts evidence)" = 1 ] || fail "restored the owner's decision $(posts evidence) times, not once"
  run 0 evaluate 5
  [ "$(posts)" = 0 ] || fail "the second run posted $(posts) statuses, not 0"
}

test_check_counts_a_failing_run_named_like_a_gate() {
  all_gates_pass
  change "commits_${HEAD_SHA}_check-runs" '.check_runs += [{id: 41, name: "merge-gate/codex", status: "completed",
    conclusion: "failure", app: {id: 555}}]'
  run 1 check 5
  says "as the ruleset counts it: check run from app 555: completed, failure"
}

test_greptile_edits_at_the_same_time_wait() {
  edits graphql-edits false "$(edit 10:00:00 greptile-apps "$(greptile_body 2 "$HEAD_SHA")")" \
    "$(edit 10:00:00 greptile-apps "$(greptile_body 5 "$HEAD_SHA")")"
  run 0 evaluate 5
  gate greptile pending "share a time and disagree"
}

test_a_status_from_a_deleted_account_shifts_nothing() {
  changed Sources/Insomnia/App.swift
  seed "$OWNER" evidence failure "the log shows no sleep"
  change "commits_${HEAD_SHA}_statuses" '[{id: 900, context: "merge-gate/evidence", state: "success",
    creator: null, description: "ok", target_url: null}] + .'
  run 0 evaluate 5
  gate evidence failure "the log shows no sleep"
}

test_merge_refuses_what_check_refuses() {
  all_gates_pass
  pr_json someone '[{"name": "accepted"}]' true
  run 2 merge 5
  says "not merging #5"
  calls ""
}

if [ $# -gt 0 ]; then
  tests=$(printf 'test_%s\n' "$@")
else
  tests=$(declare -F | sed -n 's/^declare -f \(test_.*\)$/\1/p')
fi
passed=0 failures=0
for t in $tests; do
  current=${t#test_}
  dir=$tmp/$current
  mkdir "$dir"
  out='' login=$BOT actions=true failed=no
  baseline
  "$t"
  if [ "$failed" = no ]; then
    echo "ok   $current"
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
  fi
done
echo "$passed passed, $failures failed ($BASH $BASH_VERSION)"
[ "$failures" -eq 0 ]
