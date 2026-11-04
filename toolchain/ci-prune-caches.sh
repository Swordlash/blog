#!/bin/sh
# Deletes the older copies of one of the CI's GitHub Actions caches, after a
# job has saved a new copy, so that each cache keeps one copy per ref.
#
# Usage: ci-prune-caches.sh <prefix> <saved key>, with GITHUB_REPOSITORY,
# GITHUB_REF and GH_TOKEN (a token with `actions: write`) set, as they are
# in a workflow step that passes the run's token.
#
# Why: the cabal stores and the build snapshots are saved under a key that
# ends in the run's id, because a cache key cannot be overwritten, so every
# hosted run saves a new copy. The stores are large, and the repository's
# 10 GB cache limit then evicted the older copies, main's among them, which
# are the ones a pull request falls back on. After this script, a ref holds
# only the copy just saved under <prefix>.
#
# Only entries of this run's own ref (GITHUB_REF: refs/heads/main, or
# refs/pull/<number>/merge for a pull request) are deleted. A run can
# restore the caches of its own ref and of main only, so a pull request
# that deleted main's copy would leave the next pull request with nothing.
#
# Nothing is deleted unless the saved key is listed on this ref: the save
# step only warns when it fails, and pruning then would delete the last
# good copy. The script never fails the job: a fork's pull request has a
# read-only token, and a cache that is not pruned now is pruned by the
# next run that saves one. Each case says what happened in a notice.
set -u

prefix=${1:?usage: ci-prune-caches.sh <prefix> <saved key>}
saved=${2:?usage: ci-prune-caches.sh <prefix> <saved key>}
repo=${GITHUB_REPOSITORY:?}
ref=${GITHUB_REF:?}

notice() {
  printf '::notice title=Cache pruning::%s\n' "$1"
}

if ! command -v gh >/dev/null 2>&1; then
  notice "gh is not installed: the older copies of $prefix* on $ref are kept."
  exit 0
fi

# One line per entry: its id, a space, its key. Keys have no spaces.
if ! entries=$(gh cache list --repo "$repo" --ref "$ref" --key "$prefix" \
  --limit 100 --json id,key --jq '.[] | "\(.id) \(.key)"'); then
  notice "could not list the caches $prefix* on $ref: the older copies are kept."
  exit 0
fi
printf 'Caches %s* on %s:\n%s\n' "$prefix" "$ref" "${entries:-(none)}"

if ! printf '%s\n' "$entries" | awk -v k="$saved" '$2 == k { found = 1 } END { exit !found }'; then
  notice "the saved key $saved is not listed on $ref (its save failed or was skipped): nothing is deleted."
  exit 0
fi

deleted=0
failed=0
printf '%s\n' "$entries" | {
  while read -r id key; do
    [ -n "$id" ] || continue
    [ "$key" = "$saved" ] && continue
    if gh cache delete "$id" --repo "$repo"; then
      echo "Deleted $key ($id)."
      deleted=$((deleted + 1))
    else
      failed=$((failed + 1))
    fi
  done
  if [ "$failed" -gt 0 ]; then
    notice "$failed older copies of $prefix* on $ref could not be deleted (a fork's pull request has a read-only token); the next run that saves one prunes them."
  fi
  echo "Kept $saved; deleted $deleted older copies."
}
exit 0
