#!/bin/bash
# Prints every ShellCheck finding that a directive hides in scripts/*.sh,
# one per line: the file, the check, and the line it is on. CI fails unless
# this matches .github/shellcheck-hidden.txt, which counts as config, so a
# change to what directives hide waits for the owner. When it fails, CI
# prints the new list; or run this from the repository root with the
# ShellCheck version CI pins, as $SHELLCHECK (default: shellcheck):
#
#   .github/scripts/shellcheck-hidden.sh > .github/shellcheck-hidden.txt
#
# A directive covers the next command, so a change can widen one without
# touching it: a "{" right after an existing directive and a "}" at the end
# of the file put the rest of the script under it. So this lints a copy in
# which each "#" that whitespace and "shellcheck" follow becomes "#~",
# which ShellCheck reads as no directive, with no .shellcheckrc or
# SHELLCHECK_OPTS. Each finding there is one the real lint, which must be
# clean, does not report.
#
# The copy must parse as the script does, or a changed line could end a
# here-document early, or start one, and hide the code after it. bash
# --pretty-print, from 5.2 on, parses a script without running it and
# prints it back without comments, so the copy and the script must print
# the same. A "# shellcheck" in a string, a here-document or backticks
# fails that, so spell it another way. Set $PARSE_WITH to the bash to use
# (default: bash).
set -euo pipefail
# bash reads $BASH_ENV before it parses, even with --pretty-print.
unset SHELLCHECK_OPTS BASH_ENV ENV
shellcheck=${SHELLCHECK:-shellcheck}
parser=${PARSE_WITH:-bash}

version=$("$parser" --version 2>/dev/null | sed -n '1s/^GNU bash, version \([0-9]*\)\.\([0-9]*\)\..*/\1 \2/p') ||
  version=
case $version in
  5\ [2-9] | [6-9]\ *) ;;
  *)
    echo "$parser is not bash 5.2 or later (it says \"$version\"); set PARSE_WITH to one" >&2
    exit 1
    ;;
esac

copy=$(mktemp -d)
trap 'rm -rf "$copy"' EXIT
mkdir "$copy/scripts"
for f in scripts/*.sh; do
  sed -E 's/#([[:space:]]*shellcheck)/#~\1/g' "$f" >"$copy/$f"
  if ! "$parser" --pretty-print "$f" >"$copy/parsed" ||
    ! "$parser" --pretty-print "$copy/$f" >"$copy/parsed-copy"; then
    echo "$parser could not parse $f" >&2
    exit 1
  fi
  if ! cmp -s "$copy/parsed" "$copy/parsed-copy"; then
    echo "$f has a \"# shellcheck\" outside a comment, in a string, a here-document or backticks; spell it another way" >&2
    exit 1
  fi
done

rc=0
(cd "$copy" && "$shellcheck" --shell=bash --norc -f json1 scripts/*.sh >"$copy/findings.json") || rc=$?
# ShellCheck exits 1 when it finds something, so the output must be its
# report as well: a shellcheck that is missing or fails also exits 1 here.
if [ "$rc" -gt 1 ] || ! jq -e '.comments | type == "array"' "$copy/findings.json" >/dev/null 2>&1; then
  echo "shellcheck failed (exit code $rc) or wrote no report" >&2
  exit 1
fi
# The list keeps one line per finding, so a second hidden copy of a line
# already in it still changes the list. Each line's text comes from the
# script itself, which has the copy's line numbers, so it shows comments
# as they are.
jq -r '.comments[] | "\(.file)\t\(.line)\tSC\(.code)"' "$copy/findings.json" |
  while IFS=$'\t' read -r file line code; do
    text=$(sed -n "${line}p" "$file" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    printf '%s\t%s\t%s\n' "$file" "$code" "$text"
  done | LC_ALL=C sort
