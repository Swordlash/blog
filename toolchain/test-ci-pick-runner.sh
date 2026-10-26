#!/bin/sh
# Regression tests of toolchain/ci-pick-runner.sh, against a fake curl that
# answers the GitHub API from canned responses, as
# test-ci-already-tested.sh does: what it prints for $GITHUB_OUTPUT (the
# runner the build jobs take) when the owner's machine is free, when
# another run has a job queued or running there, when only this run's own
# jobs, hosted jobs or finished ones are there, when the API fails or
# answers something it cannot read, and when the run is not trusted or a
# run by hand asks for the hosted runners (no request is made then).
#
#   sh toolchain/test-ci-pick-runner.sh
#
# Nothing leaves the machine: the fake curl is the only one on the PATH the
# script under test sees first, and it never calls the real one. The
# canned responses are shaped as the API gives them (abridged): runs carry
# nested objects with ids of their own, and jobs carry steps with statuses
# of their own, which the script must not take for the job's.
set -eu
cd "$(dirname "$0")/.."
script=$(pwd)/toolchain/ci-pick-runner.sh

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

key() {
  printf '%s' "$1" | tr '/?&=' '____'
}

# serve <request> <response>: the fake answers <request> with <response>.
serve() {
  printf '%s' "$2" >"$work/api/$(key "$1")"
}

# runs <queued|in_progress> <run objects...>: the listing of the runs with
# that status.
runs() {
  status=$1
  shift
  list=
  for object; do
    list="${list:+$list,}$object"
  done
  serve "actions/workflows/build.yml/runs?status=$status&per_page=30" \
    '{
  "total_count": '"$#"',
  "workflow_runs": ['"$list"'
  ]
}'
}

# run <id> <status>: a run object. Its actor, its repository and its head
# commit come before its own id would in a careless reading.
run() {
  printf '%s' '
    {
      "actor": { "login": "Swordlash", "id": 9001, "type": "User" },
      "repository": { "id": 7, "name": "r", "full_name": "o/r", "owner": { "id": 9001 } },
      "head_commit": { "id": "abc123", "message": "Fix a \"quoted\" thing }]" },
      "id": '"$1"',
      "name": "CI",
      "status": "'"$2"'",
      "conclusion": null,
      "jobs_url": "https://api.example/repos/o/r/actions/runs/'"$1"'/jobs",
      "run_attempt": 1
    }'
}

# jobs <run id> <job objects...>: the listing of a run's jobs.
jobs() {
  run_id=$1
  shift
  list=
  for object; do
    list="${list:+$list,}$object"
  done
  serve "actions/runs/$run_id/jobs?per_page=100" '{
  "total_count": '"$#"',
  "jobs": ['"$list"'
  ]
}'
}

# job <name> <status> <label> [labels-first]: a job object, with steps
# whose statuses are not the job's (a queued job lists no steps; a running
# one has finished, running and queued ones). With labels-first its labels
# come before its status, which the API does not promise either way.
job() {
  case $2 in
  queued | waiting) steps='[]' ;;
  in_progress) steps='[
        { "name": "Set up job", "status": "completed", "conclusion": "success", "number": 1 },
        { "name": "Run echo \"}]\"", "status": "in_progress", "conclusion": null, "number": 2 },
        { "name": "Build", "status": "queued", "conclusion": null, "number": 3 }
      ]' ;;
  *) steps='[
        { "name": "Set up job", "status": "completed", "conclusion": "success", "number": 1 }
      ]' ;;
  esac
  if [ "${4:-}" = labels-first ]; then
    printf '%s' '
    {
      "id": 51,
      "labels": [ "'"$3"'" ],
      "name": "'"$1"'",
      "steps": '"$steps"',
      "status": "'"$2"'",
      "runner_name": null
    }'
  else
    printf '%s' '
    {
      "id": 51,
      "run_id": 1,
      "status": "'"$2"'",
      "conclusion": null,
      "name": "'"$1"'",
      "steps": '"$steps"',
      "check_run_url": "https://api.example/repos/o/r/check-runs/1",
      "labels": [ "'"$3"'" ],
      "runner_name": null
    }'
  fi
}

# check <name> <expected runner> <requests: some|none> [TRUSTED] [RUNNER_INPUT]
# This run's id is 100.
check() {
  name=$1 expected=$2 requests=$3 trusted=${4-true} input=${5:-}
  rm -f "$work/summary"
  if output=$(PATH="$work/bin:$PATH" FAKE_API="$work/api" \
    GITHUB_API_URL=https://api.example GITHUB_REPOSITORY=o/r GH_TOKEN=t \
    GITHUB_RUN_ID=100 GITHUB_STEP_SUMMARY="$work/summary" \
    TRUSTED="$trusted" RUNNER_INPUT="$input" sh "$script" 2>"$work/stderr"); then
    :
  else
    output="exit $?: $output"
  fi
  problem=
  if [ "$output" != "runner=$expected" ]; then
    problem="expected runner=$expected, got: $output"
  elif [ "$requests" = none ] && [ -s "$work/api/requests" ]; then
    problem="expected no request to the API, got: $(cat "$work/api/requests")"
  elif [ "$(wc -l <"$work/summary")" -ne 1 ] || ! grep -q "^Runner: $expected, because " "$work/summary"; then
    problem="expected one line naming $expected in the summary, got: $(cat "$work/summary" 2>/dev/null)"
  fi
  if [ -z "$problem" ]; then
    printf 'ok: %s\n  (%s)\n' "$name" "$(cat "$work/stderr")"
  else
    printf 'FAIL: %s\n  %s\n  stderr: %s\n' "$name" "$problem" "$(cat "$work/stderr")"
    failures=$((failures + 1))
  fi
  rm -f "$work/api/"*
}

# This run, in progress, as every listing in progress shows it.
this_run=$(run 100 in_progress)

runs queued
runs in_progress "$this_run"
check "idle: nothing else runs, the owner's machine" self-hosted some

runs queued
runs in_progress "$this_run" "$(run 200 in_progress)"
jobs 200 "$(job plan completed ubuntu-latest)" "$(job native in_progress self-hosted)" "$(job wasm queued self-hosted)"
check "another run has a job running on the owner's machine: hosted" ubuntu-latest some

runs queued "$(run 300 queued)"
runs in_progress "$this_run"
jobs 300 "$(job plan completed ubuntu-latest)" "$(job format queued self-hosted)"
check "another run has a job queued for the owner's machine: hosted" ubuntu-latest some

runs queued
runs in_progress "$this_run" "$(run 200 in_progress)"
jobs 200 "$(job native in_progress self-hosted labels-first)"
check "a running job whose labels come before its status: hosted" ubuntu-latest some

runs queued
runs in_progress "$this_run"
jobs 100 "$(job plan in_progress ubuntu-latest)" "$(job native queued self-hosted)"
check "this run's own jobs do not count" self-hosted some

runs queued
runs in_progress "$this_run" "$(run 1000 in_progress)"
jobs 1000 "$(job native in_progress self-hosted)"
check "a run whose id begins with this run's is another run: hosted" ubuntu-latest some

runs queued
runs in_progress "$this_run" "$(run 200 in_progress)"
jobs 200 "$(job plan completed ubuntu-latest)" "$(job native in_progress ubuntu-latest)" "$(job wasm queued ubuntu-latest)"
check "hosted jobs of another run do not count" self-hosted some

runs queued
runs in_progress "$this_run" "$(run 200 in_progress)"
jobs 200 "$(job native completed self-hosted)" "$(job deploy waiting self-hosted)"
check "finished jobs, and a job waiting on an environment, do not count" self-hosted some

runs queued "$(run 300 queued)"
runs in_progress "$this_run"
jobs 300
check "another run queued with no jobs yet counts as busy: hosted" ubuntu-latest some

runs in_progress "$this_run"
check "the API failing on the runs: hosted" ubuntu-latest some

runs queued
runs in_progress "$this_run" "$(run 200 in_progress)"
check "the API failing on another run's jobs: hosted" ubuntu-latest some

runs queued
serve "actions/workflows/build.yml/runs?status=in_progress&per_page=30" '{"total_count": 1, "workflow_runs": [ { "id": 100, "name": "CI"'
check "a response cut short: hosted" ubuntu-latest some

serve "actions/workflows/build.yml/runs?status=queued&per_page=30" '{"message": "Bad credentials", "documentation_url": "https://docs.github.com/rest"}'
runs in_progress "$this_run"
check "an answer without a runs listing: hosted" ubuntu-latest some

runs queued
runs in_progress "$this_run"
check "a run that is not trusted: hosted, without asking the API" ubuntu-latest none false

runs queued
runs in_progress "$this_run"
check "no trust rule given: hosted, without asking the API" ubuntu-latest none ''

runs queued
runs in_progress "$this_run"
check "a run by hand asking for hosted: hosted, even when idle and trusted" ubuntu-latest none true hosted

runs queued
runs in_progress "$this_run"
check "a run by hand asking for self-hosted, idle: the owner's machine" self-hosted some true self-hosted

if [ "$failures" -gt 0 ]; then
  printf '%s case(s) failed.\n' "$failures"
  exit 1
fi
echo "All ci-pick-runner.sh cases passed."
