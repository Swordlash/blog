#!/bin/sh
# Regression tests of toolchain/ci-already-tested.sh, against a fake curl
# that answers the GitHub API from canned responses, in a temporary git
# repository: what it prints for $GITHUB_OUTPUT when a passing pull request
# run is found (tested=true and that run's id, which the deploy job
# downloads the built page from), when the run found has not kept the page
# it was asked to require, when no run is found, and when the API fails.
#
#   sh toolchain/test-ci-already-tested.sh
#
# Nothing leaves the machine: the fake curl is the only one on the PATH the
# script under test sees first, and it never calls the real one.
set -eu
cd "$(dirname "$0")/.."
script=$(pwd)/toolchain/ci-already-tested.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# The fake: the response is the file under $FAKE_API named after the
# request's path and query (slashes, ? and & as _), or a failure (exit 22,
# as curl -f) when there is none. Each request is logged.
mkdir -p "$work/bin" "$work/api"
cat >"$work/bin/curl" <<'EOF'
#!/bin/sh
for last; do :; done
printf '%s\n' "$last" >>"$FAKE_API/requests"
key=$(printf '%s' "${last#"$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/"}" | tr '/?&=' '____')
if [ -f "$FAKE_API/$key" ]; then
  cat "$FAKE_API/$key"
else
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
EOF
chmod 755 "$work/bin/curl"

git init -q "$work/repo"
git -C "$work/repo" -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m one
sha=$(git -C "$work/repo" rev-parse HEAD)
runs_key=$(printf 'actions/workflows/build.yml/runs?head_sha=%s&event=pull_request&status=success&per_page=1' "$sha" | tr '/?&=' '____')
artifacts_key=$(printf 'actions/runs/4242/artifacts?name=app' | tr '/?&=' '____')

# A run listing as the API gives it (abridged): the run's id first.
found='{
  "total_count": 1,
  "workflow_runs": [
    {
      "id": 4242,
      "name": "CI",
      "head_sha": "'"$sha"'",
      "repository": { "id": 7, "full_name": "o/r" }
    }
  ]
}'
none='{"total_count":0,"workflow_runs":[]}'
kept='{"total_count":1,"artifacts":[{"id":99,"node_id":"x","name":"app","size_in_bytes":10,"expired":false,"workflow_run":{"id":4242}}]}'
expired='{"total_count":1,"artifacts":[{"id":99,"node_id":"x","name":"app","size_in_bytes":10,"expired":true,"workflow_run":{"id":4242}}]}'
missing='{"total_count":0,"artifacts":[]}'

# run <name> <expected output> <runs response or -> <artifacts response or -> [REQUIRE_ARTIFACT]
run() {
  name=$1 expected=$2 runs=$3 artifacts=$4 require=${5:-}
  rm -f "$work/api/"*
  [ "$runs" = - ] || printf '%s' "$runs" >"$work/api/$runs_key"
  [ "$artifacts" = - ] || printf '%s' "$artifacts" >"$work/api/$artifacts_key"
  if output=$(cd "$work/repo" && PATH="$work/bin:$PATH" FAKE_API="$work/api" \
    GITHUB_API_URL=https://api.example GITHUB_REPOSITORY=o/r GH_TOKEN=t \
    RETRY_AFTER=0 REQUIRE_ARTIFACT="$require" sh "$script" "$sha" 2>"$work/stderr"); then
    :
  else
    output="exit $?: $output"
  fi
  if [ "$output" = "$expected" ]; then
    printf 'ok: %s\n' "$name"
  else
    printf 'FAIL: %s\n  expected: %s\n  got: %s\n  stderr: %s\n' "$name" "$expected" "$output" "$(cat "$work/stderr")"
    failures=$((failures + 1))
  fi
}

nl='
'
run "a passing run is found: tested, with its id" "tested=true${nl}run_id=4242" "$found" -
run "a passing run that kept the page, which is required" "tested=true${nl}run_id=4242" "$found" "$kept" app
run "a passing run whose page has expired, which is required" "tested=false" "$found" "$expired" app
run "a passing run that never kept the page, which is required" "tested=false" "$found" "$missing" app
run "a passing run whose artifacts cannot be read, which are required" "tested=false" "$found" - app
run "no passing run" "tested=false" "$none" -
run "the API failing" "tested=false" - -
run "a listing without a run id" "tested=false" '{"total_count":1,"workflow_runs":[{"name":"CI"}]}' -

# A stack of two pull requests merged with merge commits, from the bottom:
# lower is based on main, upper on lower. The merge of lower has main as
# its first parent, which lower contains, and lower's tree: lower's
# passing run counts. The merge of upper has lower's merge as its first
# parent, which upper does not contain: upper's passing run does not
# count, although the trees are the same, and the full CI runs on main.
stack=$work/stack
git init -q -b main "$stack"
g() { git -C "$stack" -c user.name=t -c user.email=t@example.org "$@"; }
g commit -q --allow-empty -m main
g checkout -q -b lower
echo lower >"$stack/lower"
g add lower
g commit -q -m lower
g checkout -q -b upper
echo upper >"$stack/upper"
g add upper
g commit -q -m upper
g checkout -q main
g merge -q --no-ff -m 'Merge lower' lower
lower_merge=$(g rev-parse HEAD)
g merge -q --no-ff -m 'Merge upper' upper
upper_merge=$(g rev-parse HEAD)
[ "$(g rev-parse "$upper_merge^{tree}")" = "$(g rev-parse "upper^{tree}")" ] || {
  echo "FAIL: the stack's upper merge does not have upper's tree"
  failures=$((failures + 1))
}

# stacked <name> <expected output> <pushed commit> <commit with a passing run>
stacked() {
  name=$1 expected=$2 pushed=$3 passing=$4
  rm -f "$work/api/"*
  key() { printf 'actions/workflows/build.yml/runs?head_sha=%s&event=pull_request&status=success&per_page=1' "$1" | tr '/?&=' '____'; }
  printf '%s' "$none" >"$work/api/$(key "$pushed")"
  printf '%s' "$found" >"$work/api/$(key "$passing")"
  if output=$(cd "$stack" && PATH="$work/bin:$PATH" FAKE_API="$work/api" \
    GITHUB_API_URL=https://api.example GITHUB_REPOSITORY=o/r GH_TOKEN=t \
    RETRY_AFTER=0 REQUIRE_ARTIFACT= sh "$script" "$pushed" 2>"$work/stderr"); then
    :
  else
    output="exit $?: $output"
  fi
  if [ "$output" = "$expected" ]; then
    printf 'ok: %s\n' "$name"
  else
    printf 'FAIL: %s\n  expected: %s\n  got: %s\n  stderr: %s\n' "$name" "$expected" "$output" "$(cat "$work/stderr")"
    failures=$((failures + 1))
  fi
}

stacked "a stack's lowest pull request merged: its run counts" "tested=true${nl}run_id=4242" "$lower_merge" "$(g rev-parse lower)"
stacked "a stack's upper pull request merged: its run does not count" "tested=false" "$upper_merge" "$(g rev-parse upper)"

if [ "$failures" -gt 0 ]; then
  printf '%s case(s) failed.\n' "$failures"
  exit 1
fi
echo "All ci-already-tested.sh cases passed."
