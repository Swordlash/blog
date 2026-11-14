#!/bin/sh
# Regression tests of toolchain/ci-suite-time.sh, against fake suites that
# print what hspec prints: that the suite's output passes through and its
# exit status is kept, that the five slowest examples are read from one
# list or from a list per shard and written to the job's summary, that a
# suite over its budget warns on a hosted runner (fails there once the
# budgets bind) and only says so on another, and that a failing suite
# fails whatever its time.
#
#   sh toolchain/test-ci-suite-time.sh
#
# A few seconds: the fake suites sleep for one or two seconds at most.
set -eu
cd "$(dirname "$0")/.."
script=$(pwd)/toolchain/ci-suite-time.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# A fake suite: prints an example, then the slow items of one shard (or of
# two, with "two"), sleeps $SLEEP seconds, and exits with $EXIT.
cat >"$work/suite" <<'EOF'
#!/bin/sh
echo "Slug"
echo "  mkSlug accepts a [✔]"
echo
echo "Finished in 1.0 seconds"
echo "3 examples, 0 failures"
echo
echo "Slow spec items:"
echo "  test/Test/A.hs:10:5: /A/the slowest/ (9000ms)"
echo "  test/Test/A.hs:20:5: /A/a | with a bar/ (300ms)"
echo "  test/Test/B.hs:3:3: /B/third/ (2500ms)"
if [ "${1:-}" = two ]; then
  echo
  echo "Finished in 1.0 seconds"
  echo "Slow spec items:"
  printf '  \033[33m/C/coloured in the second shard/ (4000ms)\033[0m\n'
  echo "  /D/no location/ (1200ms)"
  echo "  /E/the sixth/ (100ms)"
fi
echo "to standard error" >&2
sleep "${SLEEP:-0}"
exit "${EXIT:-0}"
EOF
chmod +x "$work/suite"

# Runs the script with the given environment words and arguments; its
# output in $work/out, its summary in $work/summary, its status in $status.
run() {
  rm -f "$work/summary"
  : >"$work/summary"
  status=0
  env GITHUB_STEP_SUMMARY="$work/summary" "$@" >"$work/out" 2>&1 || status=$?
}

# 1. A passing suite within its budget: output through, status 0, the five
# slowest in order in the summary, the bar escaped.
run RUNNER_ENVIRONMENT=github-hosted WIKI_SUITE_BUDGET=60 sh "$script" fake-suite "$work/suite" two
[ "$status" -eq 0 ] || fail "a passing suite within its budget exited $status"
grep -q 'mkSlug accepts a' "$work/out" || fail "the suite's output did not pass through"
grep -q 'to standard error' "$work/out" || fail "the suite's standard error did not pass through"
grep -q '^- `fake-suite`: [0-9]* s, budget 60 s, passed$' "$work/summary" || fail "no line for the suite in the summary: $(cat "$work/summary")"
expected='  - 9.0 s /A/the slowest/
  - 4.0 s /C/coloured in the second shard/
  - 2.5 s /B/third/
  - 1.2 s /D/no location/
  - 0.3 s /A/a \| with a bar/'
[ "$(sed -n '2,$p' "$work/summary")" = "$expected" ] || fail "the slowest five, from two shards, were not as expected: $(cat "$work/summary")"

# 2. A failing suite: its own status, whatever its time, and reported.
run RUNNER_ENVIRONMENT=github-hosted EXIT=3 WIKI_SUITE_BUDGET=60 sh "$script" fake-suite "$work/suite"
[ "$status" -eq 3 ] || fail "a failing suite exited $status, not its own 3"
grep -q 'failed (exit status 3)' "$work/summary" || fail "a failing suite was not reported as failed: $(cat "$work/summary")"

# 3. Over its budget on a hosted runner, once the budgets bind: fails,
# with the slowest named.
run RUNNER_ENVIRONMENT=github-hosted WIKI_SUITE_BUDGETS_FAIL=true SLEEP=2 WIKI_SUITE_BUDGET=1 sh "$script" fake-suite "$work/suite"
[ "$status" -eq 1 ] || fail "a suite over its budget on a hosted runner exited $status"
grep -q '^::error title=fake-suite over its budget::.*9.0 s /A/the slowest/' "$work/out" || fail "no error naming the slowest examples: $(cat "$work/out")"
grep -q 'over its budget$' "$work/summary" || fail "the summary does not say over its budget: $(cat "$work/summary")"

# 3b. Over its budget on a hosted runner while the budgets warn only (the
# script's own setting): passes, with a warning naming the slowest.
run RUNNER_ENVIRONMENT=github-hosted SLEEP=2 WIKI_SUITE_BUDGET=1 sh "$script" fake-suite "$work/suite"
[ "$status" -eq 0 ] || fail "a suite over its budget, budgets warning only, exited $status"
grep -q '^::warning title=fake-suite over its budget::.*9.0 s /A/the slowest/' "$work/out" || fail "no warning naming the slowest examples: $(cat "$work/out")"
if grep -q '::error' "$work/out"; then fail "an error while the budgets warn only"; fi
grep -q 'warns only until the budgets bind$' "$work/summary" || fail "the summary does not say the budget warns only: $(cat "$work/summary")"

# 4. Over its budget on another runner: passes, and says so.
run RUNNER_ENVIRONMENT=self-hosted WIKI_SUITE_BUDGETS_FAIL=true SLEEP=2 WIKI_SUITE_BUDGET=1 sh "$script" fake-suite "$work/suite"
[ "$status" -eq 0 ] || fail "a suite over its budget on the owner's runner exited $status"
grep -q 'which binds on the hosted runners only' "$work/summary" || fail "the summary does not say the budget binds on hosted runners only: $(cat "$work/summary")"
if grep -q '::error' "$work/out"; then fail "an error on the owner's runner"; fi

# 5. A suite with no budget and no slow items; and no summary file at all.
run sh "$script" no-such-suite true
[ "$status" -eq 0 ] || fail "a suite without a budget exited $status"
grep -q '^- `no-such-suite`: [0-9]* s, budget none, passed$' "$work/summary" || fail "a suite without a budget: $(cat "$work/summary")"
status=0
env -u GITHUB_STEP_SUMMARY sh "$script" no-such-suite false >"$work/out" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "without a summary file, a failing command exited $status"

# 6. A command that cannot be started fails.
run sh "$script" fake-suite "$work/no-such-program"
[ "$status" -ne 0 ] || fail "a missing program passed"

if [ "$failures" -gt 0 ]; then
  printf '%s failure(s)\n' "$failures" >&2
  exit 1
fi
echo "ci-suite-time.sh: all cases passed"
