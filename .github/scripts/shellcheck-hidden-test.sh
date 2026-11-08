#!/bin/bash
# Tests shellcheck-hidden.sh: a finding hidden behind a directive, wherever
# ShellCheck accepts one, must show in its list. CI runs this in the
# ShellCheck job with the ShellCheck it pins, as $SHELLCHECK, and Ubuntu's
# bash 5.2; elsewhere set $PARSE_WITH to a bash 5.2 or later.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0

# lists <script body>: the list for a repository whose only script is
# scripts/a.sh, with a bash shebang and then the body.
lists() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/scripts"
  printf '#!/bin/bash\n%s\n' "$1" >"$tmp/repo/scripts/a.sh"
  (cd "$tmp/repo" && "$here/shellcheck-hidden.sh")
}

# lint <script body>: what ShellCheck reports for a script with a bash
# shebang and then the body. ShellCheck exits 1 when it reports anything,
# so its exit code and its report are read apart.
lint() {
  local report rc=0
  printf '#!/bin/bash\n%s\n' "$1" >"$tmp/lint.sh"
  report=$("${SHELLCHECK:-shellcheck}" --shell=bash --norc -f gcc "$tmp/lint.sh") || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "shellcheck failed (exit code $rc)"
  else
    printf '%s\n' "$report"
  fi
}

# hides <name> <script body>: the directive in the body hides the SC2086 on
# "echo $x", which ShellCheck reports once the directive names another
# check instead, and the list holds it. A directive ShellCheck can't parse
# where it stands hides nothing: the lint fails on it.
hides() {
  local list control
  list=$(lists "$2")
  control=${2//disable=SC2086/disable=SC1000}
  control=${control//disable=all/disable=SC1000}
  if grep -q 'SC2086' <<<"$(lint "$2")" || ! grep -q 'SC2086' <<<"$(lint "$control")"; then
    echo "FAIL $1: the directive hides nothing"
    failed=1
  elif grep -qxF $'scripts/a.sh\tSC2086\techo $x' <<<"$list"; then
    echo "ok   $1"
  else
    echo "FAIL $1: the list is: ${list:-empty}"
    failed=1
  fi
}

hides directive $'x=$1\n# shellcheck disable=SC2086\necho $x  '
hides "directive for all checks" $'x=$1\n# shellcheck disable=all\necho $x'
hides "directive for the file" $'# shellcheck disable=SC2086\nx=$1\necho $x'
hides "braces after a directive" $'x=$1\n# shellcheck disable=SC2086\n{\ntrue\necho $x\n}'
hides "a function after a directive" $'x=$1\n# shellcheck disable=SC2086\nf() {\n  echo $x\n}\nf'
hides "no space after #" $'x=$1\n#shellcheck disable=SC2086\necho $x'
hides "tabs" $'x=$1\n#\tshellcheck\tdisable=SC2086\necho $x'
hides "spaces before #" $'x=$1\n  # shellcheck disable=SC2086\necho $x'
hides "a directive after ;" $'x=$1\ntrue;# shellcheck disable=SC2086\necho $x'
hides "a directive after (" $'x=$1\n(# shellcheck disable=SC2086\necho $x\n)'
hides "a directive after &" $'x=$1\ntrue &# shellcheck disable=SC2086\necho $x'
hides "a directive inside \$(" $'x=$1\ny=$(# shellcheck disable=SC2086\necho $x\n)\necho "$y"'
hides "a directive after a case pattern" $'x=$1\ncase $2 in\na)# shellcheck disable=SC2086\necho $x\n;;\nesac'
hides "a directive after a # in a string" $'x=$1\ntrue " #";# shellcheck disable=SC2086\necho $x'
hides "a here-document that ends at a line with a #" \
  $'x=$1\n# shellcheck disable=SC2086\n{\n: <<\'#~E\'\n#E\n: <<\'true\'\n#~E\necho $x\ntrue\n}'

# refuses <name> <script body>: the copy without directives would not parse
# as the script does, so shellcheck-hidden.sh must fail.
refuses() {
  if lists "$2" >/dev/null 2>&1; then
    echo "FAIL $1: gave a list"
    failed=1
  else
    echo "ok   $1 fails"
  fi
}

refuses "a directive inside backticks" $'x=$1\ny=`# shellcheck disable=SC2086\necho $x\n`\necho "$y"'
refuses "a # shellcheck in a string" $'echo "# shellcheck disable=SC2086"'
refuses "a # shellcheck in a here-document" $'cat <<EOF\n# shellcheck disable=SC2086\nEOF'
refuses "a here-document a changed line would end early" \
  $'x=$1\n# shellcheck disable=SC2086\n{\n: <<\'#~ shellcheck E\'\n# shellcheck E\n: <<\'true\'\n#~ shellcheck E\necho $x\ntrue\n}'
refuses "a script bash cannot parse" $'if true; then\necho'

# bash reads $BASH_ENV before --pretty-print; one that exits there would
# print nothing for the script and the copy alike. This one exits only
# while bash reads scripts/a.sh, not while it runs shellcheck-hidden.sh.
printf '%s\n' "case \$0 in *scripts/a.sh) exit 0 ;; esac" >"$tmp/bash-env"
if (BASH_ENV="$tmp/bash-env" lists $'echo "# shellcheck disable=SC2086"') >/dev/null 2>&1; then
  echo "FAIL a \$BASH_ENV that exits gave a list"
  failed=1
else
  echo "ok   a \$BASH_ENV that exits fails"
fi

list=$(lists $'x=$1\n# shellcheck disable=SC2086\necho $x # a note')
if grep -qxF $'scripts/a.sh\tSC2086\techo $x # a note' <<<"$list"; then
  echo "ok   a line's comment as it is"
else
  echo "FAIL a line's comment as it is, but the list is: ${list:-empty}"
  failed=1
fi

list=$(lists $'x=$1\n# shellcheck disable=SC2086\n{\necho $x\necho $x\n}')
if [ "$(grep -cxF $'scripts/a.sh\tSC2086\techo $x' <<<"$list")" = 2 ]; then
  echo "ok   a second hidden copy of a line"
else
  echo "FAIL a second hidden copy of a line, but the list is: ${list:-empty}"
  failed=1
fi

# A .shellcheckrc in the repository, in the home folder or SHELLCHECK_OPTS
# can hide a finding too.
rm -rf "$tmp/rc"
mkdir -p "$tmp/rc/scripts" "$tmp/home"
printf 'disable=SC2086\n' >"$tmp/rc/.shellcheckrc"
cp "$tmp/rc/.shellcheckrc" "$tmp/rc/scripts/.shellcheckrc"
cp "$tmp/rc/.shellcheckrc" "$tmp/home/.shellcheckrc"
printf '%s' $'#!/bin/bash\nx=$1\necho $x\n' >"$tmp/rc/scripts/a.sh"
for setting in HOME="$tmp/home" SHELLCHECK_OPTS=--exclude=SC2086; do
  list=$(cd "$tmp/rc" && env "$setting" "$here/shellcheck-hidden.sh") || true
  if grep -q 'SC2086' <<<"$list"; then
    echo "ok   .shellcheckrc with $setting"
  else
    echo "FAIL .shellcheckrc with $setting hides a finding from the list"
    failed=1
  fi
done

if (cd "$tmp/rc" && SHELLCHECK="$tmp/no-such-shellcheck" "$here/shellcheck-hidden.sh") >/dev/null 2>&1; then
  echo "FAIL a missing shellcheck gave a list"
  failed=1
else
  echo "ok   a missing shellcheck fails"
fi

# A shellcheck that fails may still write a report.
cat >"$tmp/failing-shellcheck" <<'EOF'
#!/bin/bash
echo '{"comments": []}'
exit 2
EOF
chmod +x "$tmp/failing-shellcheck"
if (cd "$tmp/rc" && SHELLCHECK="$tmp/failing-shellcheck" "$here/shellcheck-hidden.sh") >/dev/null 2>&1; then
  echo "FAIL a shellcheck that exits 2 gave a list"
  failed=1
else
  echo "ok   a shellcheck that exits 2 fails"
fi

# A bash without --pretty-print could print nothing for the script and the
# copy alike.
rm -rf "$tmp/repo"
mkdir -p "$tmp/repo/scripts"
printf '%s' $'#!/bin/bash\nx=$1\n# shellcheck disable=SC2086\necho $x\n' >"$tmp/repo/scripts/a.sh"
printf '#!/bin/bash\necho "GNU bash, version 5.1.16(1)-release"\n' >"$tmp/old-bash"
chmod +x "$tmp/old-bash"
if (cd "$tmp/repo" && PARSE_WITH="$tmp/old-bash" "$here/shellcheck-hidden.sh") >/dev/null 2>&1; then
  echo "FAIL bash 5.1 gave a list"
  failed=1
else
  echo "ok   bash 5.1 fails"
fi

list=$(lists $'# shellcheck disable=SC2086 # nothing to hide\nx=$1\necho "$x"')
if [ -z "$list" ]; then
  echo "ok   nothing hidden"
else
  echo "FAIL nothing hidden, but the list is: $list"
  failed=1
fi

exit "$failed"
