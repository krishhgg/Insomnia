#!/usr/bin/env bash
# A stand-in for gh that merge-gate-test.sh puts first on PATH as "gh". It
# never reaches GitHub.
#
#   gh api <path>  answers from $FAKE_GH_DIR/<key>.json, where the key is the
#                  path without the repository prefix and query string, with
#                  "/" turned into "_" (commits_<sha>_statuses). A REST list
#                  that spans pages is <key>.1.json, <key>.2.json and so on;
#                  --paginate reads them all, otherwise only the first.
#                  A commit's combined status (commits_<sha>_status) comes
#                  from its statuses, unless a test gives one.
#                  GraphQL queries read graphql-edits or graphql-threads. As
#                  real gh does, --paginate fetches another GraphQL page only
#                  while the last one says hasNextPage, and only if the query
#                  asks for pageInfo and takes $endCursor.
#                  After each read, a <key>.then.json replaces <key>.json and
#                  a <key>.then.then.json moves up behind it, so a test can
#                  change an answer between reads. A <key>.fail file makes
#                  the read fail.
#   --jq           runs through jq -r once per page, as gh does.
#   -X POST statuses/<sha>
#                  logs the post to $FAKE_GH_DIR/posts and adds the status,
#                  as $FAKE_GH_LOGIN, to the front of that commit's statuses.
#   gh pr ..., gh workflow ...
#                  log their arguments to $FAKE_GH_DIR/calls.
#
# Runs under macOS /bin/bash 3.2; needs jq.

set -euo pipefail

dir=${FAKE_GH_DIR:?}
login=${FAKE_GH_LOGIN:-github-actions[bot]}

fail() {
  echo "fake gh: $*" >&2
  exit 1
}

case ${1:-} in
  pr | workflow)
    printf '%s\n' "$*" >>"$dir/calls"
    exit 0
    ;;
  api) shift ;;
  *) fail "unexpected command: $*" ;;
esac

paginate=no method=GET filter='' path='' query='' state='' context='' description='' target_url=''
while [ $# -gt 0 ]; do
  case $1 in
    --paginate)
      paginate=yes
      shift
      ;;
    -X)
      method=$2
      shift 2
      ;;
    --jq)
      filter=$2
      shift 2
      ;;
    -f | -F)
      case $2 in
        query=*) query=${2#query=} ;;
        state=*) state=${2#state=} ;;
        context=*) context=${2#context=} ;;
        description=*) description=${2#description=} ;;
        target_url=*) target_url=${2#target_url=} ;;
      esac
      shift 2
      ;;
    -*) fail "unexpected option: $1" ;;
    *)
      path=$1
      shift
      ;;
  esac
done

path=${path%%\?*}
path=${path#repos/"${GH_REPO:?}"/}
graphql=no
if [ "$path" = graphql ]; then
  graphql=yes
  case $query in
    *userContentEdits*) key='graphql-edits' ;;
    *reviewThreads*) key='graphql-threads' ;;
    *) fail "unexpected GraphQL query: $query" ;;
  esac
else
  key=$(printf '%s' "$path" | tr / _)
fi

# The page files for a key, first page first.
pages() {
  local n=1
  if [ -f "$dir/$1.json" ]; then
    echo "$dir/$1.json"
    return 0
  fi
  while [ -f "$dir/$1.$n.json" ]; do
    echo "$dir/$1.$n.json"
    n=$((n + 1))
  done
}

if [ "$method" = POST ]; then
  case $path in
    statuses/*) sha=${path#statuses/} ;;
    *) fail "unexpected POST to $path" ;;
  esac
  [ ! -f "$dir/post.fail" ] || fail "post refused"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sha" "$login" "$context" "$state" "$description" "$target_url" >>"$dir/posts"
  key=commits_${sha}_statuses
  first=$(pages "$key" | sed -n 1p)
  if [ -z "$first" ]; then
    first=$dir/$key.json
    echo '[]' >"$first"
  fi
  next=$(pages "$key" | while IFS= read -r p; do cat "$p"; done | jq -s '[.[][].id] | (max // 0) + 1')
  jq --argjson id "$next" --arg login "$login" --arg context "$context" --arg state "$state" \
    --arg description "$description" --arg url "$target_url" \
    '[{id: $id, context: $context, state: $state, creator: {login: $login}, description: $description,
       target_url: (if $url == "" then null else $url end)}] + .' "$first" >"$first.new"
  mv "$first.new" "$first"
  echo '{}'
  exit 0
fi

[ "$method" = GET ] || fail "unexpected method $method"
[ ! -f "$dir/$key.fail" ] || fail "reading $key failed"
files=$(pages "$key")
# A commit's combined status holds the newest status for each context
# among the commit's statuses, as GitHub works it out; contexts match in
# any case.
case $key in
  commits_*_status)
    if [ -z "$files" ]; then
      files=$dir/$key.derived
      pages "${key}es" | while IFS= read -r p; do
        cat "$p"
      done | jq -s '{statuses: ([.[][]] | group_by(.context | ascii_downcase) | map(max_by(.id)))}' >"$files"
    fi
    ;;
esac
[ -n "$files" ] || fail "no fixture for $key"
if [ "$paginate" = no ]; then
  files=$(printf '%s\n' "$files" | sed -n 1p)
elif [ "$graphql" = yes ]; then
  case $query in
    *"\$endCursor"*) ;;
    *) fail "a paginated GraphQL query needs \$endCursor" ;;
  esac
  case $query in
    *pageInfo*) ;;
    *) files=$(printf '%s\n' "$files" | sed -n 1p) ;;
  esac
fi
while IFS= read -r p; do
  if [ -n "$filter" ]; then
    jq -r "$filter" "$p" || fail "jq failed on $p"
  else
    cat "$p"
  fi
  if [ "$graphql" = yes ] &&
    [ "$(jq '[.. | objects | select(has("hasNextPage")) | .hasNextPage][0] // false' "$p")" != true ]; then
    break
  fi
done <<EOF2
$files
EOF2

cur=$dir/$key
while [ -f "$cur.then.json" ]; do
  mv "$cur.then.json" "$cur.json"
  cur=$cur.then
done
