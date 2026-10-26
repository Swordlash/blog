#!/bin/sh
# For a push to main: has a pull request's CI run already tested this very
# tree, and passed? Prints `tested=true` and `run_id=<that run's id>`, or
# `tested=false`, for $GITHUB_OUTPUT; the build jobs are skipped when it is
# true, and the deploy job takes the page that run built (its artifact)
# from the run id.
#
# Pull requests are rebased onto main and main is fast-forwarded to their
# head (AGENTS.md), so the commit pushed to main is the one the pull
# request's last run built, and running CI again on it would build and test
# the same tree twice. A pull request's run builds the merge of its head
# into main as main was then, which is the head's own tree whenever the
# head already contained main; a head that main fast-forwards to contains
# it.
#
# Usage: ci-already-tested.sh <sha>, with GITHUB_REPOSITORY and GH_TOKEN
# set (a token that may read the repository's Actions runs) and the
# history fetched (fetch-depth: 0). Any doubt, an API error included,
# answers false: the full CI runs.
#
# REQUIRE_ARTIFACT, when set, names an artifact the run must still have
# for it to count: the workflow sets it to `app`, the built page, once the
# demo is deployed from main. A run that has not kept it (one from before
# the page was kept, or one whose artifact has expired) then does not
# count, and the full CI runs and builds the page again, rather than the
# deploy finding nothing to deploy.
set -eu

sha=${1:?usage: ci-already-tested.sh <sha>}
: "${GITHUB_REPOSITORY:?}" "${GH_TOKEN:?}"
api=${GITHUB_API_URL:-https://api.github.com}
require_artifact=${REQUIRE_ARTIFACT:-}

# The commits whose pull-request run would have tested this tree: the
# commit itself (a fast-forward), and, for a merge commit made by GitHub's
# merge button, its second parent when that already contained the first
# (a pull request brought up to date before it was merged).
candidates=$sha
if second=$(git rev-parse --verify --quiet "$sha^2"); then
  if git merge-base --is-ancestor "$sha^1" "$second" &&
    [ "$(git rev-parse "$sha^{tree}")" = "$(git rev-parse "$second^{tree}")" ]; then
    candidates="$candidates $second"
  fi
fi

# A GET of the API, or nothing on an error.
get() {
  curl -fsS \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$api/repos/$GITHUB_REPOSITORY/$1" || true
}

# Whether run $1 still has an artifact named $require_artifact: the
# listing by that name counts at least one, and one of them has not
# expired.
kept() {
  artifacts=$(get "actions/runs/$1/artifacts?name=$require_artifact" | tr -d '\n')
  kept_count=$(printf '%s' "$artifacts" | grep -o '"total_count": *[0-9]*' | head -n 1 | grep -o '[0-9]*$' || true)
  if [ -z "$kept_count" ]; then
    printf 'Could not read the artifacts of run %s from the API (response: %.200s).\n' "$1" "$artifacts" >&2
    return 1
  fi
  if [ "$kept_count" -gt 0 ] && printf '%s' "$artifacts" | grep -q '"expired": *false'; then
    return 0
  fi
  printf 'Run %s has not kept the artifact %s (expired, or never made).\n' "$1" "$require_artifact" >&2
  return 1
}

# The runs listing can lag a run that has just finished (the pull request's
# often has, by minutes), so a miss is asked again once after a pause.
look() {
  for candidate in $candidates; do
    # Plain text tools only: the runner need not have jq, and a missing tool
    # must not pass for "no run found" without saying so.
    response=$(get "actions/workflows/build.yml/runs?head_sha=$candidate&event=pull_request&status=success&per_page=1" | tr -d '\n')
    count=$(printf '%s' "$response" | grep -o '"total_count": *[0-9]*' | head -n 1 | grep -o '[0-9]*$' || true)
    if [ -z "$count" ]; then
      printf 'Could not read the runs of %s from the API (response: %.200s).\n' "$candidate" "$response" >&2
      continue
    fi
    printf '%s passing pull request run(s) of %s.\n' "$count" "$candidate" >&2
    if [ "$count" -gt 0 ]; then
      # The run's own id is the first field of its object, the first of
      # the list.
      run_id=$(printf '%s' "$response" | sed -n 's/.*"workflow_runs": *\[ *{ *"id": *\([0-9][0-9]*\).*/\1/p')
      if [ -z "$run_id" ]; then
        printf 'Could not read the id of the run that tested %s (response: %.200s).\n' "$candidate" "$response" >&2
        continue
      fi
      if [ -n "$require_artifact" ] && ! kept "$run_id"; then
        continue
      fi
      printf 'A pull request run, %s, already tested %s and passed.\n' "$run_id" "$candidate" >&2
      return 0
    fi
  done
  return 1
}

if look || { sleep "${RETRY_AFTER:-30}" && look; }; then
  echo tested=true
  echo "run_id=$run_id"
  exit 0
fi
printf 'No passing pull request run tested %s: running the full CI.\n' "$sha" >&2
echo tested=false
