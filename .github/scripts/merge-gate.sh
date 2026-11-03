#!/usr/bin/env bash
# The merge gate for pull requests into main.
#
# The main ruleset refuses a merge until every required check passes at the
# pull request's head commit, the newest commit on its branch. Besides the
# four CI jobs it requires five commit statuses, which this script posts and
# reads:
#
#   merge-gate/greptile  Greptile reviewed the head and scored it 5/5. Read
#                        from the newest description edit made by
#                        greptile-apps (GitHub records who made each edit),
#                        and only if that description names one score and
#                        one reviewed commit, so text the author adds next to
#                        Greptile's block cannot supply them.
#   merge-gate/accepted  The owner added the "accepted" label: they want the
#                        change in Insomnia. The newest add or removal of the
#                        label must be the owner adding it.
#   merge-gate/evidence  The maintainer checked a real-Mac report for the
#                        head, or the head changes only paths that never run
#                        on a user's Mac (is_exempt).
#   merge-gate/config    The head leaves CI, review and build config alone
#                        (is_config), the owner wrote the pull request, or the
#                        owner OK'd those changes at the head.
#   merge-gate/codex     The maintainer's Codex review of the head has nothing
#                        open.
#
# A status belongs to one commit, so a push starts every gate over. For
# evidence, config and codex, a success or failure the owner posted on the
# head decides, whatever the files say; the workflow fills in the rest.
#
# Usage
#   merge-gate.sh list all | <pr>...
#       Prints the open pull requests into main, or the numbers given, as a
#       JSON array for the workflow's matrix.
#   merge-gate.sh evaluate <pr>
#       Posts the five statuses for the pull request's head. Only the merge
#       gate workflow posts them, so that every run for one pull request
#       waits its turn in one concurrency group; elsewhere, set DRY_RUN=1 to
#       print them, or dispatch the workflow.
#   merge-gate.sh post <pr> <head sha> codex|evidence|config success|failure|pending <description> [url]
#       Posts the owner's decision on a gate, on the head it names. Refused
#       if the pull request's head is another commit. Posting pending hands
#       the gate back to the workflow. Then starts the workflow for the pull
#       request, so a run that read the statuses before the post cannot
#       leave its result on top.
#   merge-gate.sh check <pr>
#       Prints every check the main ruleset requires, for the head, and exits
#       0 only if all pass. Each gate's newest status must be a success, and
#       so must what the gate works out to from GitHub's data now. It also
#       needs each CI job to have tested a merge with the current main, and
#       a ruleset that whoever runs this cannot bypass to require every
#       check here. Last, if all that passed, it reads the head, the gates
#       and main again, and fails if any of them changed during the check.
#   merge-gate.sh rerun <pr>
#       Marks the pull request draft and then ready, which starts CI on a
#       merge with the current main without changing the head.
#   merge-gate.sh merge <pr>
#       Runs check, then merges with a merge commit. GitHub refuses the merge
#       if the head moved after the check, or if a required check fails by
#       then. A label removed, a lower Greptile score or a main that moved
#       in the few seconds of the check's last reads and the merge does not
#       stop it.
#
# Environment: GH_REPO (default krishhgg/Insomnia). DRY_RUN=1 prints the
# statuses evaluate and post would send instead of sending them.
#
# Runs under macOS /bin/bash 3.2 and the bash on GitHub's Ubuntu runners;
# needs gh, which brings its own jq for --jq. merge-gate-test.sh tests it
# against a stand-in for gh.

set -euo pipefail

die() {
  echo "merge-gate: $*" >&2
  exit 2
}

REPO=${GH_REPO:-krishhgg/Insomnia}
OWNER=${REPO%%/*}
case $OWNER in
  '' | *[!A-Za-z0-9-]*) die "unexpected repository owner in GH_REPO: $REPO" ;;
esac
BASE=main
# GitHub Actions, the app every CI check run must come from.
ACTIONS_APP_ID=15368
CI_CHECKS=(
  "Swift test and release build (macOS 26)"
  "Swift test and release build (macOS 27)"
  "ShellCheck scripts"
  "Lint workflows"
)
GATES=(greptile accepted evidence config codex)

usage() {
  sed -n '/^# Usage/,/^# Environment/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

need_number() {
  case $1 in
    '' | *[!0-9]*) die "not a pull request number: $1" ;;
  esac
}

# Paths that never run on a user's Mac, so a change to them alone needs no
# real-Mac report. skills/ is not here: agents follow those files on users'
# Macs.
is_exempt() {
  case $1 in
    docs/* | Tests/* | .github/* | .greptile/* | README.md | CONTRIBUTING.md | SECURITY.md | LICENSE | .gitignore) return 0 ;;
  esac
  return 1
}

# Paths that may steer a check or a review, so a fork's change to them waits
# for the owner. This is an allowlist: only kinds of files that no check
# reads as settings pass, and anything else counts, since a list of the
# dangerous files always misses one. Swift sources and tests, text docs,
# the product's scripts, plists, and the root README and LICENSE pass.
# Images do not: no reviewer can read one, and a script could source it.
# Within those, a name starting with a dot counts (.greptile/ folders,
# .shellcheckrc, .gitignore and .ignore, which zizmor honors, and
# .gitattributes, which can hide a file from the diff), as does an
# AGENTS.md or CLAUDE.md, which Codex and other review agents follow, and
# scripts/check-lid-simulation-gate.sh, which CI runs from the branch.
# .greptile/files.json gives Greptile SECURITY.md and CONTRIBUTING.md as
# guidance for every review, so they are left off the allowlist. It also
# gives docs/spec.md and docs/release-validation.md, and in its scoped
# entries backstop.sh and RuntimeState.swift, but contributors are meant to
# change those: the spec with the behavior, the validation record with
# their real-Mac checks. Each reviewer sees such a change in the diff, a
# comment anywhere in a change could argue the same way, and the Codex
# review, which a pull request cannot steer, weighs it. The tests check
# that every other file files.json names counts. A fork's pull_request run uses the
# workflow files on the fork's branch, so .github/ is never safe, and
# SwiftPM builds from Package.swift or a Package@swift-<version>.swift at
# the root. The Mac runners check out to a case-insensitive disk, so the
# names that count match in any case: scripts/Check-Lid-Simulation-Gate.sh
# lands on the real one. The allowlist matches names exactly, case
# included: CI's scripts/*.sh globs skip scripts/backstop.SH, which that
# disk still opens as scripts/backstop.sh. The disk also folds Unicode
# (scripts/ spelled with U+017F, a long s, lands on scripts/), so any name
# with a byte outside printable ASCII counts too.
is_config() {
  local path name
  if LC_ALL=C grep -q '[^ -~]' <<<"$1"; then
    return 0
  fi
  path=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  name=${path##*/}
  case $path in
    */.* | scripts/*/* | scripts/check-lid-simulation-gate.sh) return 0 ;;
  esac
  case $name in
    agents.md | agents.override.md | claude.md | claude.local.md | gemini.md) return 0 ;;
  esac
  case $1 in
    Sources/*.swift | Tests/*.swift | Tests/*.h | Tests/*.c) return 1 ;;
    docs/*.md | docs/*.html | docs/*.svg) return 1 ;;
    scripts/*.sh | scripts/*.swift | skills/*.md) return 1 ;;
    Resources/*.plist) return 1 ;;
    README.md | LICENSE) return 1 ;;
  esac
  return 0
}

post() { # <sha> <context> <state> <description> [url]
  local sha=$1 context=$2 state=$3 description=${4:0:140} url=${5:-}
  if [ "${DRY_RUN:-}" = 1 ]; then
    printf '  would post %s %s on %s: %s\n' "$context" "$state" "${sha:0:7}" "$description"
    return 0
  fi
  set -- -X POST "repos/$REPO/statuses/$sha" -f state="$state" -f context="$context" -f description="$description"
  if [ -n "$url" ]; then
    set -- "$@" -f target_url="$url"
  fi
  gh api "$@" >/dev/null || return 1
  printf '  posted %s %s on %s: %s\n' "$context" "$state" "${sha:0:7}" "$description"
}

# One line per merge-gate context at a commit, tab-separated: context, in
# lower case since GitHub treats MERGE-GATE/codex as merge-gate/codex; the
# newest status's state, creator, description and url; then the state,
# description and url of the newest one the owner posted ("none" if none).
# An empty creator (a deleted account), description or url reads "-": read
# splits on runs of tabs, so an empty field would shift the rest. A tab or
# line break in a field reads as a space, and nothing is escaped (@tsv
# would double a backslash), so a description evaluate posts back reads
# the same next time. Reads every page, since a commit keeps every status
# posted on it, and gh applies --jq to one page at a time, so awk picks
# the newest across pages.
gate_statuses() {
  local rows
  rows=$(gh api --paginate "repos/$REPO/commits/$1/statuses?per_page=100" --jq '
    def f: if . == null or . == "" then "-" else . end;
    .[] | select(.context | ascii_downcase | startswith("merge-gate/"))
    | [.id, (.context | ascii_downcase), .state, (.creator.login | f), (.description | f), (.target_url | f)]
    | map(tostring | gsub("[\t\r\n]"; " ")) | join("\t")') || return 1
  printf '%s\n' "$rows" | sort -n | awk -v owner="$OWNER" '
    BEGIN { FS = OFS = "\t" }
    $2 != "" {
      if (!($2 in newest)) order[++n] = $2
      newest[$2] = $3 OFS $4 OFS $5 OFS $6
      if ($4 == owner) own[$2] = $3 OFS $5 OFS $6
    }
    END {
      for (i = 1; i <= n; i++) {
        c = order[i]
        print c, newest[c], ((c in own) ? own[c] : "none" OFS "-" OFS "-")
      }
    }'
}

# How many lines a string holds; an empty one holds none.
count_lines() {
  if [ -z "$1" ]; then
    echo 0
  else
    printf '%s\n' "$1" | wc -l | tr -d ' '
  fi
}

# "<scores> <reviewed commits> <score> <reviewed sha>" from the newest
# description edit by greptile-apps: how many score markers and "Last
# reviewed commit" lines that description holds, then the first of each
# ("none" if absent). Each edit's diff is the whole description after it.
# "tie tie tie tie" if Greptile's newest edits share a time but differ, since
# nothing then says which came last.
greptile_review() {
  local rows newest results
  # shellcheck disable=SC2016 # GraphQL and jq variables
  rows=$(gh api graphql --paginate -F owner="$OWNER" -F name="${REPO#*/}" -F number="$1" -f query='
    query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          userContentEdits(first: 100, after: $endCursor) {
            nodes { editedAt editor { login } diff }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }' --jq '.data.repository.pullRequest.userContentEdits.nodes[]
      | select(.editor.login == "greptile-apps")
      | (.diff // "") as $d
      | [.editedAt,
         ([$d | match("greptile_confidence_score:"; "g")] | length),
         ([$d | match("Last reviewed commit:"; "g")] | length),
         (($d | capture("greptile_confidence_score:(?<s>[0-9]+)").s) // "none"),
         (($d | capture("Last reviewed commit: .*?/commit/(?<c>[0-9a-f]{40})").c) // "none")]
      | map(tostring) | @tsv') || return 1
  if [ -z "$rows" ]; then
    echo "0 0 none none"
    return 0
  fi
  newest=$(printf '%s\n' "$rows" | cut -f 1 | sort | tail -n 1)
  results=$(printf '%s\n' "$rows" | awk -F '\t' -v t="$newest" '$1 == t' | cut -f 2- | sort -u)
  if [ "$(count_lines "$results")" -gt 1 ]; then
    echo "tie tie tie tie"
    return 0
  fi
  printf '%s\n' "$results" | tr '\t' ' '
}

# "labeled <login>", "unlabeled <login>" or "none": the newest time the
# accepted label was added to or removed from the pull request, and by whom.
accepted_event() {
  local events
  events=$(gh api --paginate "repos/$REPO/issues/$1/events?per_page=100" --jq '.[]
    | select((.event == "labeled" or .event == "unlabeled") and .label.name == "accepted")
    | [.id, .event, .actor.login] | @tsv') || return 1
  if [ -z "$events" ]; then
    echo none
    return 0
  fi
  printf '%s\n' "$events" | sort -n | tail -n 1 | cut -f 2,3 | tr '\t' ' '
}

# What decide_gates works out: the pull request (read_pr), the merge-gate
# statuses on its head (gate_statuses), and for each gate, at its place in
# GATES, the state, description and url it should have now.
PR_STATE='' PR_BASE='' PR_HEAD='' PR_AUTHOR='' PR_LABELED='' PR_DRAFT='' PR_MERGEABLE='' EXISTING=''
D_STATE=() D_DESC=() D_URL=()

read_pr() { # <pr>
  local info
  info=$(gh api "repos/$REPO/pulls/$1" --jq '[.state, .base.ref, .head.sha, (.user.login // "ghost"),
    ([.labels[].name] | index("accepted") != null), .draft, (.mergeable | tostring)] | @tsv') || return 1
  IFS=$'\t' read -r PR_STATE PR_BASE PR_HEAD PR_AUTHOR PR_LABELED PR_DRAFT PR_MERGEABLE <<<"$info"
}

# decide <gate> <state> <description>
# Records what the gate should say. For evidence, config and codex, the
# owner's newest success or failure on the head replaces what the caller
# worked out. Reads $EXISTING.
decide() {
  local gate=$1 state=$2 description=$3 url='' i=0 g line own_state own_description own_url
  case $gate in
    evidence | config | codex)
      line=$(printf '%s\n' "$EXISTING" | awk -F '\t' -v c="merge-gate/$gate" '$1 == c')
      if [ -n "$line" ]; then
        IFS=$'\t' read -r _ _ _ _ _ own_state own_description own_url <<<"$line"
        case $own_state in
          success | failure)
            state=$own_state
            description=$own_description
            url=$own_url
            if [ "$url" = - ]; then
              url=''
            fi
            ;;
        esac
      fi
      ;;
  esac
  for g in "${GATES[@]}"; do
    if [ "$g" = "$gate" ]; then
      break
    fi
    i=$((i + 1))
  done
  D_STATE[i]=$state
  D_DESC[i]=${description:0:140}
  D_URL[i]=$url
}

# decide_gates <pr>: works out every gate for PR_HEAD, which read_pr set,
# from what GitHub says now. Reads everything before evaluate posts
# anything. Returns 1 if a read fails.
decide_gates() {
  local pr=$1 head=$PR_HEAD short=${PR_HEAD:0:7} review scores reviews score reviewed event compare count files f tree links
  local needs_evidence=no touches_config=no
  EXISTING=$(gate_statuses "$head") || return 1

  # Greptile can review a push without rewriting its summary (its check run
  # on #34's c04e86b added a comment and left the summary on 2ff8c6c). A
  # score for an older commit does not count, so that waits for a re-review.
  review=$(greptile_review "$pr") || return 1
  read -r scores reviews score reviewed <<<"$review"
  if [ "$scores" = tie ]; then
    decide greptile pending "Greptile's two newest edits share a time and disagree; waiting for its next one"
  elif [ "$scores" -gt 1 ] || [ "$reviews" -gt 1 ]; then
    decide greptile failure "the description holds $scores Greptile scores and $reviews reviewed commits; only Greptile's block may"
  elif [ "$reviewed" = none ]; then
    decide greptile pending "waiting for Greptile's first review"
  elif [ "$reviewed" != "$head" ]; then
    decide greptile pending "waiting for a Greptile score for $short; its summary covers ${reviewed:0:7}"
  elif [ "$score" = 5 ]; then
    decide greptile success "Greptile scored $short 5/5"
  else
    decide greptile failure "Greptile scored $short $score/5; the gate needs 5/5"
  fi

  event=$(accepted_event "$pr") || return 1
  if [ "$PR_LABELED" = true ] && [ "$event" = "labeled $OWNER" ]; then
    decide accepted success "the owner accepted this change"
  elif [ "$PR_LABELED" = true ]; then
    decide accepted pending "the accepted label was not added by the owner ($event)"
  else
    decide accepted pending "waiting for the owner's accepted label"
  fi

  # The files of this head, not of the pull request, which a push can move
  # while this runs. The comparison lists at most 300 files; at 300, assume
  # the worst. A file also counts as config if its diff adds a setting a
  # check reads from inside the file: a ShellCheck directive (a
  # "# shellcheck disable=all" line silences every warning in its script,
  # and CI's .github/shellcheck-hidden.txt check catches a change that
  # widens an existing directive without touching it),
  # or a Swift @diagnose attribute (SE-0522, in the Swift 6.4 that CI's
  # macOS 27 job runs) or @warn, in any spelling Swift accepts, such as
  # @`diagnose`, since the release build treats warnings as errors. GitHub
  # sends no diff for a file too big to show or for a binary file, such as
  # an image, and one NUL byte makes a script binary. No reviewer can read
  # such a file, and a script could source it, so any file without a diff
  # counts too, unless it was removed. A control character in a name
  # becomes U+00FF, which is_config counts, so a line break cannot split one
  # name into two that each look safe.
  compare=$(gh api "repos/$REPO/compare/$BASE...$head" --jq '
    def clean: gsub("[[:cntrl:]]"; "\u00ff");
    def sets: .status != "removed" and
      (.patch == null or
       (.patch | test("(^|\n)\\+[^\n]*(#[ \t]*shellcheck[ \t]|@[ \t]*\\x60?(warn|diagnose)\\x60?([^A-Za-z0-9_]|$))")));
    (.files // [] | length),
    (.files // [] | .[] | (.filename, (.previous_filename // empty)) | "path\t" + clean),
    (.files // [] | .[] | select(sets) | "sets\t" + (.filename | clean))') || return 1
  count=$(printf '%s\n' "$compare" | sed -n 1p)
  files=$(printf '%s\n' "$compare" | sed 1d)
  # A changed symlink or submodule counts too. CI follows a symlink, so
  # scripts/x.sh pointing at a binary docs/x.png would be linted with
  # whatever directives the image holds, and git keeps no content for a
  # submodule. The head's tree gives each file's mode (120000 for a
  # symlink, 160000 for a submodule). If GitHub cuts the tree short,
  # assume the worst.
  tree=$(gh api "repos/$REPO/git/trees/$head?recursive=1" --jq '
    (.truncated | tostring),
    (.tree // [] | .[] | select(.mode == "120000" or .mode == "160000") | .path | gsub("[[:cntrl:]]"; "\u00ff"))') ||
    return 1
  links=$(printf '%s\n' "$tree" | sed 1d)
  if [ "$(printf '%s\n' "$tree" | sed -n 1p)" != false ]; then
    touches_config=yes
  fi
  if [ "$count" -ge 300 ]; then
    needs_evidence=yes
    touches_config=yes
  else
    while IFS=$'\t' read -r kind f; do
      [ -n "$f" ] || continue
      if [ "$kind" = sets ]; then
        touches_config=yes
        continue
      fi
      if ! is_exempt "$f"; then
        needs_evidence=yes
      fi
      if is_config "$f" || { [ -n "$links" ] && grep -Fxq -- "$f" <<<"$links"; }; then
        touches_config=yes
      fi
    done <<<"$files"
  fi

  if [ "$needs_evidence" = no ]; then
    decide evidence success "not needed: only docs, tests and repo tooling change"
  else
    decide evidence pending "waiting for a real-Mac report on $short, checked by the maintainer"
  fi

  if [ "$touches_config" = no ]; then
    decide config success "CI, review and build config unchanged"
  elif [ "$PR_AUTHOR" = "$OWNER" ]; then
    decide config success "config changes come from the owner"
  else
    decide config pending "changes CI, review or build config; waiting for the owner's OK at $short"
  fi

  decide codex pending "waiting for the maintainer's Codex review of $short"
}

# set_gate <sha> <gate index>: posts what decide recorded for the gate,
# unless the newest status already says it. Reads $EXISTING.
set_gate() {
  local sha=$1 i=$2 gate=${GATES[$2]} line cur_state cur_creator cur_description cur_url
  line=$(printf '%s\n' "$EXISTING" | awk -F '\t' -v c="merge-gate/$gate" '$1 == c')
  if [ -n "$line" ]; then
    IFS=$'\t' read -r _ cur_state cur_creator cur_description cur_url _ <<<"$line"
    if [ "$cur_state" = "${D_STATE[i]}" ] && [ "$cur_description" = "${D_DESC[i]}" ] &&
      [ "$cur_url" = "${D_URL[i]:--}" ]; then
      printf '  %s: still %s (%s)\n' "$gate" "$cur_state" "$cur_creator"
      return 0
    fi
  fi
  post "$sha" "merge-gate/$gate" "${D_STATE[i]}" "${D_DESC[i]}" "${D_URL[i]}"
}

evaluate_one() {
  local pr=$1 i
  need_number "$pr"
  read_pr "$pr" || return 1
  if [ "$PR_STATE" != open ] || [ "$PR_BASE" != "$BASE" ]; then
    echo "#$pr: $PR_STATE into $PR_BASE, skipped"
    return 0
  fi
  echo "#$pr at ${PR_HEAD:0:7} by $PR_AUTHOR"
  decide_gates "$pr" || return 1
  for i in "${!GATES[@]}"; do
    set_gate "$PR_HEAD" "$i" || return 1
  done
}

list_cmd() {
  local prs pr
  [ $# -ge 1 ] || usage
  if [ "$1" = all ]; then
    prs=$(gh api --paginate "repos/$REPO/pulls?state=open&base=$BASE&per_page=100" --jq '.[].number') ||
      die "could not list open pull requests"
  else
    for pr in "$@"; do
      need_number "$pr"
    done
    prs=$*
  fi
  # shellcheck disable=SC2086 # split the numbers one per line
  printf '[%s]\n' "$(printf '%s\n' $prs | paste -sd , -)"
}

evaluate_cmd() {
  [ $# -eq 1 ] || usage
  if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${DRY_RUN:-}" != 1 ]; then
    die "only the merge gate workflow posts these; set DRY_RUN=1 to print them, or run: gh workflow run merge-gate.yml -f pr=$1"
  fi
  evaluate_one "$1" || die "could not evaluate #$1"
}

post_cmd() {
  local pr sha gate state description url head
  [ $# -ge 5 ] || usage
  pr=$1 sha=$2 gate=$3 state=$4 description=$5 url=${6:-}
  need_number "$pr"
  case $sha in
    *[!0-9a-f]*) die "not a full commit sha: $sha" ;;
  esac
  [ ${#sha} -eq 40 ] || die "not a full commit sha: $sha"
  case $gate in
    codex | evidence | config) ;;
    *) die "the owner decides codex, evidence or config, not $gate" ;;
  esac
  case $state in
    success | failure | pending) ;;
    *) die "not a status state: $state" ;;
  esac
  head=$(gh api "repos/$REPO/pulls/$pr" --jq .head.sha) || die "could not read #$pr"
  [ "$sha" = "$head" ] || die "#$pr's head is $head, not $sha"
  post "$sha" "merge-gate/$gate" "$state" "$description" "$url" || die "could not post the status"
  # A workflow run that read the statuses before this post can still post
  # over it. A run started now queues behind that one and puts this back.
  if [ "${DRY_RUN:-}" != 1 ]; then
    gh workflow run merge-gate.yml -R "$REPO" -f pr="$pr" ||
      echo "merge-gate: could not start the merge gate workflow for #$pr; its hourly run will catch up" >&2
  fi
}

# expected_pair <context> <app id or ->: whether the rows check_pr prints
# for the CI jobs and the gates already cover this required check: a CI
# job pinned to GitHub Actions, or a merge-gate status pinned to no app.
expected_pair() {
  local c
  for c in "${CI_CHECKS[@]}"; do
    if [ "$c" = "$1" ]; then
      [ "$2" = "$ACTIONS_APP_ID" ]
      return
    fi
  done
  for c in "${GATES[@]}"; do
    if [ "merge-gate/$c" = "$1" ]; then
      [ "$2" = - ]
      return
    fi
  done
  return 1
}

# required_check <context> <app id or -> [all|runs|status]: prints why
# GitHub would not count this required check as passed on the head, or
# nothing if it would. From each app (only the named app, if the rule
# names one), the newest check run under each spelling of the name must be
# a success, so a passing Mac-Mini cannot hide a failing mac-mini. So must
# the newest status with the name, whatever app the rule names: GitHub
# needs both when a check run and a status share a name, and a status does
# not say which app posted it, so this fails closed. Names match in any
# case, as GitHub matches status contexts, but only a check run with the
# exact name counts as there. With "all", at least one check run from the
# named app, or for a rule that names no app one check run or status, must
# exist. "runs" looks only at check runs and
# "status" only at the status, and neither needs anything to exist; they
# are for pairs whose rows check_pr prints already cover the rest. Reads
# $runs and $latest from check_pr.
required_check() {
  local context=$1 app=$2 mode=${3:-all} apps='' a names name line status conclusion state seen=no
  if [ "$mode" != status ]; then
    if [ "$app" = - ]; then
      apps=$(printf '%s\n' "$runs" | awk -F '\t' -v n="$context" 'tolower($2) == tolower(n) { print $5 }' | sort -u)
    else
      apps=$app
    fi
  fi
  for a in $apps; do
    names=$(printf '%s\n' "$runs" | awk -F '\t' -v n="$context" -v a="$a" 'tolower($2) == tolower(n) && $5 == a { print $2 }' |
      sort -u)
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      line=$(printf '%s\n' "$runs" | awk -F '\t' -v n="$name" -v a="$a" '$2 == n && $5 == a' | sort -n | tail -n 1)
      IFS=$'\t' read -r _ _ status conclusion _ <<<"$line"
      if [ "$conclusion" != success ]; then
        echo "check run from app $a: $status, $conclusion"
        return 0
      fi
      if [ "$name" = "$context" ]; then
        seen=yes
      fi
    done <<<"$names"
  done
  if [ "$mode" = runs ]; then
    return 0
  fi
  state=$(printf '%s\n' "$latest" | awk -F '\t' -v c="$context" '
    $1 == tolower(c) && (s == "" || $2 != "success") { s = $2 }
    END { print s }')
  if [ -n "$state" ]; then
    if [ "$state" != success ]; then
      echo "status: $state"
      return 0
    fi
    if [ "$app" = - ]; then
      seen=yes
    fi
  fi
  if [ "$mode" = all ] && [ "$seen" = no ]; then
    if [ "$app" = - ]; then
      echo "no check run or status"
    else
      echo "no check run from app $app"
    fi
  fi
}

FAILS=0
row() { # pass|fail <name> <detail>
  if [ "$1" = pass ]; then
    printf 'pass  %-40s %s\n' "$2" "$3"
  else
    printf 'FAIL  %-40s %s\n' "$2" "$3"
    FAILS=$((FAILS + 1))
  fi
}

CHECKED_HEAD='' CHECKED_MAIN=''

# still_ready <pr>: reads the pull request, its gates and main again and
# prints what changed since check_pr read them ("; " between), or nothing:
# the head or main moved, the pull request is no longer open into main,
# ready and free of conflicts, or a gate's newest status or what it works
# out to now is no longer a success from the workflow or the owner.
# Returns 1 if a read fails.
still_ready() {
  local i gate line gstate creator now problems=''
  read_pr "$1" || return 1
  if [ "$PR_HEAD" != "$CHECKED_HEAD" ]; then
    echo "the head moved to ${PR_HEAD:0:7}"
    return 0
  fi
  if [ "$PR_STATE" != open ] || [ "$PR_BASE" != "$BASE" ]; then
    problems="the pull request is now $PR_STATE into $PR_BASE"
  fi
  if [ "$PR_DRAFT" != false ]; then
    problems="$problems${problems:+; }the pull request is now a draft"
  fi
  if [ "$PR_MERGEABLE" != true ]; then
    problems="$problems${problems:+; }GitHub now gives mergeable as $PR_MERGEABLE"
  fi
  decide_gates "$1" || return 1
  for i in "${!GATES[@]}"; do
    gate=${GATES[i]}
    line=$(printf '%s\n' "$EXISTING" | awk -F '\t' -v c="merge-gate/$gate" '$1 == c')
    gstate=missing creator=-
    if [ -n "$line" ]; then
      IFS=$'\t' read -r _ gstate creator _ <<<"$line"
    fi
    if [ "$gstate" != success ]; then
      problems="$problems${problems:+; }merge-gate/$gate is now $gstate"
    elif [ "$creator" != "github-actions[bot]" ] && [ "$creator" != "$OWNER" ]; then
      problems="$problems${problems:+; }merge-gate/$gate is now a success from $creator"
    elif [ "${D_STATE[i]}" != success ]; then
      problems="$problems${problems:+; }merge-gate/$gate now works out to ${D_STATE[i]}: ${D_DESC[i]}"
    fi
  done
  now=$(gh api "repos/$REPO/commits/$BASE" --jq .sha) || return 1
  if [ "$now" != "$CHECKED_MAIN" ]; then
    problems="$problems${problems:+; }$BASE moved from ${CHECKED_MAIN:0:7} to ${now:0:7}"
  fi
  printf '%s' "$problems"
}

check_pr() {
  local pr=$1 head short main_sha changed runs name line status conclusion id notes count parsed tested tested_head
  local i gate gstate creator description url open_threads rules rid bypass strict='' strict_rules required latest
  local context pinned label reason missing='' unpinned='' threads_rule
  need_number "$pr"
  FAILS=0
  read_pr "$pr" || die "could not read #$pr"
  head=$PR_HEAD
  short=${head:0:7}
  main_sha=$(gh api "repos/$REPO/commits/$BASE" --jq .sha) || die "could not read $BASE"
  CHECKED_HEAD=$head
  CHECKED_MAIN=$main_sha
  echo "#$pr at $head, $BASE at $main_sha"

  if [ "$PR_STATE" = open ] && [ "$PR_BASE" = "$BASE" ]; then
    row pass "open into $BASE" ""
  else
    row fail "open into $BASE" "$PR_STATE into $PR_BASE"
  fi
  if [ "$PR_DRAFT" = false ]; then
    row pass "ready for review" ""
  else
    row fail "ready for review" "the pull request is a draft"
  fi

  # Each CI job's newest run on the head must have passed, and must have
  # tested a merge with the current main: its "Tested merge" note, which
  # ci.yml writes from the merge commit's parents, names the main it used.
  # It needs exactly one note, since the pull request's own code could
  # print a second one.
  runs=$(gh api --paginate "repos/$REPO/commits/$head/check-runs?filter=all&per_page=100" \
    --jq '.check_runs[] | [.id, .name, .status, (.conclusion // "none"), .app.id] | @tsv') ||
    die "could not read check runs"
  for name in "${CI_CHECKS[@]}"; do
    line=$(printf '%s\n' "$runs" | awk -F '\t' -v n="$name" -v a="$ACTIONS_APP_ID" '$2 == n && $5 == a' | sort -n | tail -n 1)
    if [ -z "$line" ]; then
      row fail "$name" "no run on $short"
      continue
    fi
    IFS=$'\t' read -r id _ status conclusion _ <<<"$line"
    if [ "$status" != completed ] || [ "$conclusion" != success ]; then
      row fail "$name" "$status, $conclusion"
      continue
    fi
    notes=$(gh api --paginate "repos/$REPO/check-runs/$id/annotations?per_page=100" \
      --jq '.[] | select(.title == "Tested merge") | .message | gsub("\n"; " ")' </dev/null) ||
      die "could not read annotations"
    count=$(count_lines "$notes")
    parsed=$(printf '%s\n' "$notes" | sed -n 's/^main \([0-9a-f]\{40\}\), pull request head \([0-9a-f]\{40\}\)$/\1 \2/p')
    read -r tested tested_head <<<"${parsed:-none none}"
    if [ "$count" != 1 ]; then
      row fail "$name" "success, but $count Tested merge notes, not 1; run: $0 rerun $pr"
    elif [ "$tested_head" != "$head" ]; then
      row fail "$name" "success, but its note names head ${tested_head:0:7}"
    elif [ "$tested" != "$main_sha" ]; then
      row fail "$name" "success on $BASE ${tested:0:7}, but $BASE is now ${main_sha:0:7}; run: $0 rerun $pr"
    else
      row pass "$name" "success on $BASE ${main_sha:0:7}"
    fi
  done

  # Each gate's newest status must be a success, and so must what the gate
  # works out to now: a label removed, a lower Greptile score or the
  # owner's newer failure counts before the workflow catches up. Only the
  # merge gate workflow and the owner post these; anyone else who can post
  # a status (someone given write access, an installed app) does not count.
  decide_gates "$pr" || die "could not read what the gates depend on"
  for i in "${!GATES[@]}"; do
    gate=${GATES[i]}
    line=$(printf '%s\n' "$EXISTING" | awk -F '\t' -v c="merge-gate/$gate" '$1 == c')
    if [ -z "$line" ]; then
      row fail "merge-gate/$gate" "no status on $short; it is now ${D_STATE[i]}: ${D_DESC[i]}"
      continue
    fi
    IFS=$'\t' read -r _ gstate creator description url _ <<<"$line"
    if [ "$url" != - ]; then
      description="$description ($url)"
    fi
    if [ "$gstate" != success ] && [ "${D_STATE[i]}" = success ]; then
      row fail "merge-gate/$gate" "$gstate, but it is now success; run: gh workflow run merge-gate.yml -R $REPO -f pr=$pr"
    elif [ "$gstate" != success ]; then
      row fail "merge-gate/$gate" "$gstate: $description [$creator]"
    elif [ "$creator" != "github-actions[bot]" ] && [ "$creator" != "$OWNER" ]; then
      row fail "merge-gate/$gate" "success from $creator, who is neither the workflow nor the owner"
    elif [ "${D_STATE[i]}" != success ]; then
      row fail "merge-gate/$gate" "posted success, but it is now ${D_STATE[i]}: ${D_DESC[i]}"
    else
      row pass "merge-gate/$gate" "$description [$creator]"
    fi
  done

  # Each required check, and each rule on resolving conversations, with the
  # ruleset it comes from.
  # shellcheck disable=SC2016 # $r is a jq variable
  rules=$(gh api --paginate "repos/$REPO/rules/branches/$BASE?per_page=100" --jq '.[]
    | if .type == "required_status_checks" then
        .ruleset_id as $r | .parameters.required_status_checks[]
        | ["check", $r, .context, (.integration_id // "-")]
      elif .type == "pull_request" then
        ["threads", .ruleset_id, (.parameters.required_review_thread_resolution // false), "-"]
      else empty end
    | map(tostring) | @tsv') || die "could not read the $BASE rules"
  required=$(printf '%s\n' "$rules" | awk 'BEGIN { FS = OFS = "\t" } $1 == "check" { print $3, $4 }' | sort -u)
  latest=$(gh api --paginate "repos/$REPO/commits/$head/status?per_page=100" \
    --jq '.statuses[] | [(.context | ascii_downcase), .state] | @tsv') ||
    die "could not read statuses"
  # Every required check as GitHub counts it. The rows above already cover
  # a CI job's check run from GitHub Actions and a gate's statuses (the end
  # of this reads them again), so for those pairs this looks only for a
  # failing status named like a CI job or a failing check run named like a
  # gate.
  while IFS=$'\t' read -r context pinned; do
    [ -n "$context" ] || continue
    label=$context
    if [ "$pinned" != - ]; then
      label="$context (app $pinned)"
    fi
    if expected_pair "$context" "$pinned"; then
      case $context in
        merge-gate/*) reason=$(required_check "$context" "$pinned" runs) ;;
        *) reason=$(required_check "$context" "$pinned" status) ;;
      esac
      if [ -n "$reason" ]; then
        row fail "$label" "as the ruleset counts it: $reason"
      fi
      continue
    fi
    reason=$(required_check "$context" "$pinned")
    if [ -z "$reason" ]; then
      row pass "$label" "success"
    else
      row fail "$label" "$reason"
    fi
  done <<<"$required"

  # shellcheck disable=SC2016 # GraphQL variables
  open_threads=$(gh api graphql --paginate -F owner="$OWNER" -F name="${REPO#*/}" -F number="$pr" -f query='
    query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $endCursor) {
            nodes { isResolved }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not) | "open"') ||
    die "could not read review threads"
  count=$(count_lines "$open_threads")
  if [ "$count" = 0 ]; then
    row pass "review conversations resolved" ""
  else
    row fail "review conversations resolved" "$count open"
  fi

  case $PR_MERGEABLE in
    true) row pass "no conflicts with $BASE" "" ;;
    false) row fail "no conflicts with $BASE" "the branch conflicts with $BASE" ;;
    *) row fail "no conflicts with $BASE" "GitHub is still working it out; run check again" ;;
  esac

  # A rule counts here only if it comes from a ruleset that whoever runs
  # this cannot bypass: gh pr merge --admin skips the others.
  for rid in $(printf '%s\n' "$rules" | cut -f 2 | sort -u); do
    bypass=$(gh api "repos/$REPO/rulesets/$rid" --jq .current_user_can_bypass) || die "could not read ruleset $rid"
    if [ "$bypass" = never ]; then
      strict="$strict $rid"
    fi
  done
  strict_rules=$(printf '%s\n' "$rules" | awk -F '\t' -v ids="$strict" '
    BEGIN { n = split(ids, a, " "); for (i = 1; i <= n; i++) keep[a[i]] = 1 }
    $2 in keep')
  for context in "${CI_CHECKS[@]}" "${GATES[@]/#/merge-gate/}"; do
    if [ -z "$(printf '%s\n' "$strict_rules" | awk -F '\t' -v c="$context" '$1 == "check" && $3 == c')" ]; then
      missing="$missing${missing:+, }$context"
      continue
    fi
    case $context in
      merge-gate/*) ;;
      *)
        if [ -z "$(printf '%s\n' "$strict_rules" | awk -F '\t' -v c="$context" -v a="$ACTIONS_APP_ID" '$1 == "check" && $3 == c && $4 == a')" ]; then
          unpinned="$unpinned${unpinned:+, }$context"
        fi
        ;;
    esac
  done
  threads_rule=false
  if [ -n "$(printf '%s\n' "$strict_rules" | awk -F '\t' '$1 == "threads" && $3 == "true"')" ]; then
    threads_rule=true
  fi
  if [ -z "$missing$unpinned" ] && [ "$threads_rule" = true ]; then
    row pass "GitHub enforces all of this" "a ruleset you cannot bypass requires every check above"
  else
    row fail "GitHub enforces all of this" "not required by a ruleset you cannot bypass: ${missing:-none}; not pinned to GitHub Actions: ${unpinned:-none}; resolved conversations required: $threads_rule"
  fi

  # The rows above came from reads spread over several seconds, and the CI
  # rows compared each note with main as it was at the start. If they all
  # passed, read what can change without a push once more, last.
  if [ "$FAILS" -eq 0 ]; then
    changed=$(still_ready "$pr") || die "could not read #$pr again"
    if [ -n "$changed" ]; then
      row fail "nothing changed during this check" "$changed; run check again"
    fi
  fi

  if [ "$FAILS" -eq 0 ]; then
    echo "READY: #$pr at $head"
    return 0
  fi
  echo "NOT READY: #$pr at $short, $FAILS failing"
  return 1
}

# --admin uses the owner's bypass of the "only krishhgg may merge" ruleset,
# which blocks every update to main that does not use it. It does not get
# past the ruleset that requires the checks above: that one has no bypass
# list, and on 2026-10-12 a copy of it refused --admin merges of #107 for a
# missing status and for an open conversation. GitHub refuses the merge if
# the head moved after the check, and checks every required status, check
# run and conversation as they are then. What it cannot check is a change
# the workflow has not posted yet: a label removed, a lower Greptile score
# or a main that moved. check_pr's last step reads those once more, so only
# a change during those few reads (a few seconds) or before GitHub merges
# goes unseen. The workflow posts a label or score change within about a
# minute; a main that moved stays untested until CI runs on the merge.
merge_cmd() {
  [ $# -eq 1 ] || usage
  check_pr "$1" || die "not merging #$1"
  gh pr merge "$1" -R "$REPO" --merge --admin --match-head-commit "$CHECKED_HEAD"
}

rerun_cmd() {
  [ $# -eq 1 ] || usage
  need_number "$1"
  gh pr ready "$1" -R "$REPO" --undo
  gh pr ready "$1" -R "$REPO"
}

[ $# -ge 1 ] || usage
command=$1
shift
case $command in
  list) list_cmd "$@" ;;
  evaluate) evaluate_cmd "$@" ;;
  post) post_cmd "$@" ;;
  check)
    [ $# -eq 1 ] || usage
    check_pr "$1"
    ;;
  rerun) rerun_cmd "$@" ;;
  merge) merge_cmd "$@" ;;
  *) usage ;;
esac
