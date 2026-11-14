#!/bin/sh
# Regression tests of toolchain/smoke-test.sh's running of its parts, in a
# copy of it beside fake suites (a fake toolchain/smoke-suite.sh and node
# programs) and a fake cabal: one after another by default, each part's
# output as it comes; up to WIKI_SMOKE_JOBS side by side, each log printed
# in the order of the list; and in both, a failing part fails the command
# and is named, and the others still run. A few seconds.
#
# Nothing here stands on timing or on the order the system happens to run
# processes in: that two suites ran side by side is shown by each waiting,
# as it runs, until the other has started (FAKE_MEET), which only
# succeeds if both run at once.
#
#   sh toolchain/test-smoke-test.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

mkdir -p "$work/tree/toolchain" "$work/bin" "$work/home"
cp "$root/toolchain/smoke-test.sh" "$root/toolchain/caller-paths.sh" "$work/tree/toolchain/"
: > "$work/tree/toolchain/changelog-stamp.sh"
# A suite: says it started and ended, with the program it was given, in a
# record of the run, and fails when it is FAKE_FAILING. A suite named in
# FAKE_MEET, once started, waits until every other suite named there has
# started too, and fails, naming the one it waited for, if that has not
# happened within a minute: a deadline for a broken run, not a guess at
# how long the other takes.
cat > "$work/tree/toolchain/smoke-suite.sh" <<'EOF'
#!/bin/sh
echo "start $1" >> "$FAKE_ORDER"
: > "$FAKE_STARTED/$1"
echo "suite $1 runs $WIKI_SMOKE_PROGRAM"
case " ${FAKE_MEET:-} " in
  *" $1 "*)
    for other in $FAKE_MEET; do
      tries=0
      until [ -e "$FAKE_STARTED/$other" ]; do
        tries=$((tries + 1))
        if [ "$tries" -gt 600 ]; then
          echo "suite $1 waited a minute for suite $other to start beside it" >&2
          exit 3
        fi
        sleep 0.1
      done
    done
    ;;
esac
echo "end $1" >> "$FAKE_ORDER"
[ "$1" != "${FAKE_FAILING:-}" ]
EOF
cat > "$work/tree/toolchain/run-smoke-tests.mjs" <<'EOF'
console.log("the node programs");
EOF
cat > "$work/bin/cabal" <<'EOF'
#!/bin/sh
case $1 in
  list-bin) for last; do :; done; echo "/built/$last" ;;
esac
EOF
chmod +x "$work/bin/cabal"

run() {
  : > "$work/order"
  rm -rf "$work/started"
  mkdir "$work/started"
  status=0
  (
    cd "$work/tree"
    env PATH="$work/bin:$PATH" WIKI_TOOLCHAIN_HOME="$work/home" FAKE_ORDER="$work/order" FAKE_STARTED="$work/started" \
      WIKI_TEST_DATABASE_URL= GITHUB_ACTIONS= "$@" sh toolchain/smoke-test.sh
  ) > "$work/out" 2>&1 || status=$?
}

# 1. One after another by default: each suite starts after the one before
# ends (the script waits for each before it starts the next), with its
# built program, and the node programs last.
run
[ "$status" -eq 0 ] || fail "in a row, passing suites exited $status: $(cat "$work/out")"
[ "$(tr '\n' ' ' < "$work/order")" = "start demo end demo start passkeys end passkeys start server end server " ] ||
  fail "in a row, the order was: $(cat "$work/order")"
grep -q 'suite demo runs /built/wiki-smoke:test:wiki-smoke-demo' "$work/out" || fail "the demo did not get its built program: $(cat "$work/out")"
grep -q 'the node programs' "$work/out" || fail "the node programs did not run"
grep -q 'not run (WIKI_TEST_DATABASE_URL is not set)' "$work/out" || fail "PostgreSQL's suite not said to be skipped"

# 2. A failing suite in a row: the others still run, the command fails
# and names it.
run FAKE_FAILING=passkeys WIKI_SMOKE_EXTRA=waits
[ "$status" -eq 1 ] || fail "in a row, a failing suite gave $status"
grep -q 'The smoke test failed: passkeys.' "$work/out" || fail "the failing suite was not named: $(cat "$work/out")"
[ "$(grep -c '^end ' "$work/order")" -eq 4 ] || fail "in a row, not every suite ran: $(cat "$work/order")"

# 3. Side by side, two at a time: the first two run at once (each waits
# for the other to start, which passes only if both run together), so the
# first two records are their starts, in whichever order; every suite
# runs, and the logs come in the order of the list, which the script
# keeps whatever order the suites end in.
run FAKE_MEET="demo passkeys" WIKI_SMOKE_JOBS=2
[ "$status" -eq 0 ] || fail "side by side, passing suites exited $status: $(cat "$work/out")"
[ "$(sed -n 1,2p "$work/order" | sort | tr '\n' ' ')" = "start demo start passkeys " ] ||
  fail "side by side, the first two did not start together: $(cat "$work/order")"
[ "$(grep -c '^end ' "$work/order")" -eq 3 ] || fail "side by side, not every suite ran: $(cat "$work/order")"
[ "$(grep -o 'The smoke suite [a-z-]*: passed' "$work/out" | tr '\n' ' ')" = "The smoke suite demo: passed The smoke suite passkeys: passed The smoke suite server: passed The smoke suite node-programs: passed " ] ||
  fail "side by side, the reports were not in the order of the list: $(cat "$work/out")"

# 4. Side by side, a failing suite: its log is printed and it is named.
run FAKE_FAILING=server WIKI_SMOKE_JOBS=3
[ "$status" -eq 1 ] || fail "side by side, a failing suite gave $status"
grep -q 'suite server runs' "$work/out" || fail "the failing suite's log was not printed"
grep -q 'The smoke test failed: server.' "$work/out" || fail "side by side, the failing suite was not named: $(cat "$work/out")"

# 5. A count that is not a positive number is refused.
run WIKI_SMOKE_JOBS=0
[ "$status" -eq 2 ] || fail "WIKI_SMOKE_JOBS=0 gave $status"

if [ "$failures" -gt 0 ]; then
  printf '%s failure(s)\n' "$failures" >&2
  exit 1
fi
echo "smoke-test.sh: all cases passed"
