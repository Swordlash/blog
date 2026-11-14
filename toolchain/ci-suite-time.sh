#!/bin/sh
# Run one test suite, time it and report it: CI's check that keeps each
# suite within its time (WP5.110 of docs/PLAN.md).
#
#   sh toolchain/ci-suite-time.sh <suite> <command> [args...]
#
# The command's output passes through as it comes and is kept in a log.
# Then a few lines go to the job's summary ($GITHUB_STEP_SUMMARY), when
# there is one: the suite's name, its wall time, its budget, and its five
# slowest examples. The examples are read from the list hspec prints for
# --print-slow-items, which the caller asks for. A suite that runs in
# several shards prints one list per shard; the five slowest of all are
# taken.
#
# A suite that took longer than its budget on GitHub's hosted runners is
# named in a warning, with the same five examples, and, once the budgets
# bind (budgets_fail below), fails. On another runner, such as the
# owner's, the time is only reported: the owner's machine is slower while
# sessions build on it, and its times are not the ones the budgets were
# set from. The exit status is the command's when the command failed, 1
# when it passed but over a binding budget, and 0 otherwise.
#
# The budgets are below, in one place, each with the measure it was set
# from. A budget leaves room for the runners' spread: the same wasm suite
# took 425 and 580 seconds on two runs of one day (2026-11-12 and 13).
# WIKI_SUITE_BUDGET, in seconds, takes the place of the table's budget,
# and WIKI_SUITE_BUDGETS_FAIL the place of budgets_fail, for this script's
# own test (toolchain/test-ci-suite-time.sh).
set -eu

# Whether a suite over its budget on a hosted runner fails its job (true)
# or is only named in a warning (false). False since 2026-11-14: the
# budgets below are estimates until they are set from hosted runs, and a
# budget the runners' spread can cross would make a failure of chance.
# Turned to true once they are (WP5.110 of docs/PLAN.md).
budgets_fail=false
budgets_fail=${WIKI_SUITE_BUDGETS_FAIL:-$budgets_fail}

suite=${1:?usage: ci-suite-time.sh <suite> <command> [args...]}
shift
[ "$#" -gt 0 ] || { echo "ci-suite-time.sh: no command to run for $suite" >&2; exit 2; }

# The budget of a suite, in seconds of wall time on a hosted runner (4
# cores, with the job's other suites running beside it); empty for a suite
# without one.
budget_of() {
  case $1 in
    # Set on 2026-11-14 (WP5.110), to be set again from the first hosted
    # run that has them, which measures each suite as CI runs it.
    #
    # wiki-core-test on wasm, under Node, beside the browser suite: 790 s
    # on 2026-11-13 (run 43504709479) before WP5.110 cut its cases on wasm;
    # after the cut and WP5.108 (#273), 111 s alone on a quiet machine, so
    # about 120 to 200 s expected on a hosted runner beside the browser
    # suite. The 265 s that one day added would cross the budget.
    wiki-core-test) echo 420 ;;
    # wiki-api-test on wasm: 2.3 to 2.8 s from 2026-11-11 to 13.
    wiki-api-test) echo 60 ;;
    # The browser suite, its two shards side by side: 352 and 378 s on
    # 2026-11-13 (run 43504709479), 183 and 162 s two days before.
    wiki-app-browser-test) echo 600 ;;
    # The smoke suites, side by side in the smoke job. One after another
    # on 2026-11-13 (run 43504709479) they took: waits 17 s, screenshots
    # 10 s, demo 106 s, passkeys 5 s, the server 109 s on SQLite and 114 s
    # on PostgreSQL. Side by side on four cores of a loaded machine, where
    # one after another the demo took 161 s and the server 189 s: waits 35
    # s, screenshots 48 s, demo 352 s, passkeys 40 s, the server 373 s and
    # 388 s.
    smoke-waits) echo 120 ;;
    smoke-screenshots) echo 120 ;;
    smoke-demo) echo 420 ;;
    smoke-passkeys) echo 120 ;;
    smoke-server) echo 420 ;;
    smoke-server-postgres) echo 420 ;;
    *) echo "" ;;
  esac
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
log=$work/log

start=$(date +%s)
# The status goes through a file: a pipeline's status is its last
# command's (tee's), and dash has no pipefail.
{
  status=0
  "$@" || status=$?
  echo "$status" > "$work/status"
} 2>&1 | tee "$log"
end=$(date +%s)
seconds=$((end - start))
status=$(cat "$work/status" 2>/dev/null || echo 1)

# The five slowest examples: hspec's lines after "Slow spec items:", such
# as "  test/Test/Diff.hs:51:3: /Wiki.Core.Diff/keeps .../ (16292ms)",
# without their source location and colours, the slowest first.
esc=$(printf '\033')
slowest=$(
  sed "s/$esc\[[0-9;]*m//g" "$log" |
    awk '/^Slow spec items:/ { on = 1; next } on && /\([0-9]+ms\)$/ { print; next } { on = 0 }' |
    sed -n 's/^ *[^ ]*:[0-9]*:[0-9]*: //; s/^\(.*\) (\([0-9]*\)ms)$/\2 \1/p' |
    sort -rn | head -n 5 |
    awk '{ ms = $1; $1 = ""; sub(/^ /, ""); printf "%.1f s %s\n", ms / 1000, $0 }'
)

budget=${WIKI_SUITE_BUDGET:-$(budget_of "$suite")}
hosted=false
[ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] && hosted=true
over=false
if [ -n "$budget" ] && [ "$seconds" -gt "$budget" ]; then
  over=true
fi

if [ "$status" -ne 0 ]; then
  verdict="failed (exit status $status)"
elif [ "$over" = true ] && [ "$hosted" = true ] && [ "$budgets_fail" = true ]; then
  verdict="over its budget"
elif [ "$over" = true ] && [ "$hosted" = true ]; then
  verdict="over its budget, which warns only until the budgets bind"
elif [ "$over" = true ]; then
  verdict="over its budget, which binds on the hosted runners only"
else
  verdict="passed"
fi
budget_text=none
[ -z "$budget" ] || budget_text="$budget s"
line="$suite: $seconds s, budget $budget_text, $verdict"
printf '\n%s\n' "$line"
[ -z "$slowest" ] || printf '%s\n' "$slowest" | sed 's/^/  /'

# One write, so that suites run side by side do not mix their lines.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  block=$(
    printf -- '- `%s`: %s s, budget %s, %s\n' "$suite" "$seconds" "$budget_text" "$verdict"
    [ -z "$slowest" ] || printf '%s\n' "$slowest" | sed 's/|/\\|/g; s/^/  - /'
  )
  printf '%s\n' "$block" >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$status" -ne 0 ]; then
  exit "$status"
fi
if [ "$over" = true ] && [ "$hosted" = true ]; then
  list=$(printf '%s\n' "$slowest" | awk 'NF { printf "%s%s", sep, $0; sep = "; " }')
  if [ "$budgets_fail" = true ]; then
    echo "::error title=$suite over its budget::$suite took $seconds s, over its budget of $budget s (toolchain/ci-suite-time.sh). The slowest examples: ${list:-none listed}"
    exit 1
  fi
  echo "::warning title=$suite over its budget::$suite took $seconds s, over its budget of $budget s (toolchain/ci-suite-time.sh; budgets warn only, for now). The slowest examples: ${list:-none listed}"
fi
