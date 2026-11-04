#!/bin/sh
# Regression tests of toolchain/ci-prune-caches.sh, against a fake gh that
# answers `gh cache list` from a canned listing and logs every call: which
# copies it deletes when the saved key is listed, that it lists only this
# ref's caches, and that it deletes nothing, and still succeeds, when the
# saved key is missing, when the listing fails and when a delete fails.
#
#   sh toolchain/test-ci-prune-caches.sh
#
# Nothing leaves the machine: the fake gh is the only one on the PATH the
# script under test sees, and it never calls the real one.
set -eu
cd "$(dirname "$0")/.."
script=$(pwd)/toolchain/ci-prune-caches.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# The fake: `gh cache list` prints $FAKE/listing (the lines the real one's
# --jq makes) or fails when $FAKE/list-fails exists; `gh cache delete`
# fails when $FAKE/delete-fails exists. Each call is logged, one per line.
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE/calls"
case "$1 $2" in
  "cache list")
    [ ! -e "$FAKE/list-fails" ] || exit 1
    cat "$FAKE/listing"
    ;;
  "cache delete")
    [ ! -e "$FAKE/delete-fails" ] || exit 1
    ;;
  *) exit 2 ;;
esac
FAKE
chmod 755 "$work/bin/gh"

# case <name> <listing> [flag file]: runs the script with the listing, and
# the flag file (list-fails, delete-fails) when given, and leaves its
# output in $work/out and the fake's calls in $work/fake/calls.
case_() {
  name=$1
  rm -rf "$work/fake"
  mkdir -p "$work/fake"
  printf '%s' "$2" >"$work/fake/listing"
  [ -z "${3:-}" ] || touch "$work/fake/$3"
  : >"$work/fake/calls"
  if ! PATH="$work/bin:$PATH" FAKE="$work/fake" GITHUB_REPOSITORY=o/r \
    GITHUB_REF=refs/pull/7/merge \
    sh "$script" Linux-store- Linux-store-v1-30-1 >"$work/out" 2>&1; then
    echo "FAIL $name: the script failed"
    cat "$work/out"
    failures=$((failures + 1))
  fi
}

# expect <name> <expected deletes, one id per line>: the ids deleted.
expect_deletes() {
  got=$(sed -n 's/^cache delete \([^ ]*\) .*/\1/p' "$work/fake/calls")
  if [ "$got" = "$2" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: deleted [$got], expected [$2]"
    cat "$work/out"
    failures=$((failures + 1))
  fi
}

# expect_output <name> <text>: the script's output contains the text.
expect_output() {
  if grep -q -F -e "$2" "$work/out"; then
    echo "ok   $1"
  else
    echo "FAIL $1: no \"$2\" in the output"
    cat "$work/out"
    failures=$((failures + 1))
  fi
}

listing='3 Linux-store-v1-30-1
2 Linux-store-v1-20-1
1 Linux-store-abc123-10-2
'

case_ 'older copies are deleted' "$listing"
expect_deletes 'older copies are deleted, the saved one is kept' '2
1'
if grep -q -F -e 'cache list --repo o/r --ref refs/pull/7/merge --key Linux-store-' "$work/fake/calls"; then
  echo "ok   only this ref's caches are listed"
else
  echo "FAIL only this ref's caches are listed: $(cat "$work/fake/calls")"
  failures=$((failures + 1))
fi

case_ 'a key that only starts with the saved one' '4 Linux-store-v1-30-10
3 Linux-store-v1-30-1
'
expect_deletes 'a key that only starts with the saved one is deleted' '4'

case_ 'the saved key is missing' '2 Linux-store-v1-20-1
1 Linux-store-abc123-10-2
'
expect_deletes 'nothing is deleted when the saved key is missing' ''
expect_output 'and it says so' 'is not listed on refs/pull/7/merge'

case_ 'the listing fails' "$listing" list-fails
expect_deletes 'nothing is deleted when the listing fails' ''
expect_output 'and it says so' 'could not list the caches'

case_ 'the deletes fail' "$listing" delete-fails
expect_output 'a failed delete is reported, not fatal' "2 older copies of Linux-store-* on refs/pull/7/merge could not be deleted"

case_ 'only the saved copy' '3 Linux-store-v1-30-1
'
expect_deletes 'nothing else, nothing deleted' ''
expect_output 'and it says so' 'deleted 0 older copies'

if [ "$failures" -gt 0 ]; then
  echo "$failures failures"
  exit 1
fi
echo "all passed"
