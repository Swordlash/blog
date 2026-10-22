#!/bin/sh
# For a push to main: has a pull request's CI run already tested this very
# tree, and passed? Prints `tested=true` or `tested=false`, for
# $GITHUB_OUTPUT; the build jobs are skipped when it is true.
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
set -eu

sha=${1:?usage: ci-already-tested.sh <sha>}
: "${GITHUB_REPOSITORY:?}" "${GH_TOKEN:?}"
api=${GITHUB_API_URL:-https://api.github.com}

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

for candidate in $candidates; do
  count=$(curl -fsS \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$api/repos/$GITHUB_REPOSITORY/actions/workflows/build.yml/runs?head_sha=$candidate&event=pull_request&status=success&per_page=1" |
    jq -r '.total_count' 2>/dev/null || true)
  case $count in
    '' | *[!0-9]*) count=0 ;;
  esac
  if [ "$count" -gt 0 ]; then
    printf 'A pull request run already tested %s and passed.\n' "$candidate" >&2
    echo tested=true
    exit 0
  fi
done
printf 'No passing pull request run tested %s: running the full CI.\n' "$sha" >&2
echo tested=false
