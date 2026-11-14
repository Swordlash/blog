#!/bin/sh
# The smoke test, in both its modes, on the build npm run build-wasm wrote:
#
#   npm run smoke-test [-- dir]
#
# wiki-smoke's suites, native Haskell programs that drive the built page in
# headless Chromium through haskell-halogen-playwright, which waits on the
# page's program rather than on the clock (toolchain/smoke-suite.sh runs
# each):
#
# 1. demo: the serverless demo, as a static host serves it (the build's own
#    pages). A [dir] given is its WIKI_DEMO_DIR, and every suite's.
# 2. passkeys: the assistant's keys synced with a real passkey, from
#    Chromium's virtual authenticator, against a real wiki-server.
# 3. server: the same app.wasm with the server's page (wiki-app-prerender
#    --server), served by a real wiki-server on a temporary data directory,
#    with an administrator made on its console who signs in, driven end to
#    end, with the encrypted spaces' walk and their canary.
# 4. server-postgres: the same on PostgreSQL, when one is at hand:
#    WIKI_TEST_DATABASE_URL names a database of a server on which the suite
#    may make two databases of its own (postgres://user@host:port/postgres,
#    with a query such as ?host=/run/postgresql when it is on a socket),
#    with psql (WIKI_TEST_PSQL, else the PATH's) to make and drop them, and
#    the pg_dump and pg_restore the server's backups run (WIKI_TEST_PG_DUMP
#    and WIKI_TEST_PG_RESTORE, else the PATH's), as toolchain/ci-postgres.sh
#    gives them in CI. Without it, the PostgreSQL run is reported as not run.
#
# Then toolchain/run-smoke-tests.mjs, for what tests JavaScript modules
# without a browser and stays in node: toolchain/test-assistant.mjs, the
# writing assistant's providers over the real SDKs, against a fetch that
# answers as the providers' APIs do (it needs no build), and
# toolchain/test-tikz-letters.mjs, the error a TikZ picture shows for a
# letter TikZJax's fonts lack.
#
# The suites need wiki-server and wiki-app-prerender built natively, which
# this builds first at -O0 in dist-newstyle/native-fast, with every suite's
# test program, in one run of cabal. Then each suite runs its built program
# (WIKI_SMOKE_PROGRAM of toolchain/smoke-suite.sh), without cabal, one
# after another, its output as it comes. WIKI_SMOKE_EXTRA names more suites
# to run with them (CI gives "waits screenshots").
#
# WIKI_SMOKE_JOBS=<n> runs up to n suites side by side instead, each its
# output in a log of its own, printed when it ends, in the order of the
# list: cabal is not run then, since it must not run twice at once in one
# build directory, and each suite picks free ports and a temporary
# directory of its own. It is faster on a machine with cores to spare, but
# each suite then runs slower, as on a slowed-down processor nobody asked
# for: on four cores each took about twice as long, the whole 26% less than
# in a row, and two races a suite did not wait for failed CI's runs by
# chance (2026-11-14). So one at a time is the default, and CI's: races are
# looked for on purpose, by the weekly run with the processor throttled
# (decision 81 of docs/PLAN.md).
#
# Every part runs whatever the others' outcome, and the command fails if
# any did, or if one gave no status.
#
# Paths given here relative to the directory this is run from (the [dir],
# WIKI_SERVER, WIKI_PRERENDER) are read from there (toolchain/caller-paths.sh).
set -eu
called_from=$(pwd)
. "$(dirname "$0")/caller-paths.sh"
cd "$(dirname "$0")/.."
toolchain_home=$(path_from_caller "${WIKI_TOOLCHAIN_HOME:-}")
toolchain_home=${toolchain_home:-$HOME}
if [ -r "$toolchain_home/.wiki-toolchain/env" ]; then
  # shellcheck source=/dev/null
  . "$toolchain_home/.wiki-toolchain/env"
fi
native_project=${NATIVE_PROJECT:-cabal-native-fast.project}
native_build_dir=${NATIVE_BUILDDIR:-dist-newstyle/native-fast}
suites="${WIKI_SMOKE_EXTRA:-} demo passkeys server"
if [ -n "${WIKI_TEST_DATABASE_URL:-}" ]; then
  suites="$suites server-postgres"
else
  echo "The server's smoke suite on PostgreSQL: not run (WIKI_TEST_DATABASE_URL is not set)." >&2
fi
# The test program of a suite: server-postgres is the server's suite.
target_of() {
  case $1 in
    screenshots | waits | demo | passkeys | server) echo "wiki-smoke:test:wiki-smoke-$1" ;;
    server-postgres) echo "wiki-smoke:test:wiki-smoke-server" ;;
    *)
      printf 'No smoke suite %s: screenshots, waits, demo, passkeys, server or server-postgres\n' "$1" >&2
      return 2
      ;;
  esac
}
# A suite's name as a part of a shell variable's name.
var_of() {
  printf '%s' "$1" | tr '-' '_'
}
targets=
for suite in $suites; do
  target=$(target_of "$suite") || exit 2
  case " $targets " in
    *" $target "*) ;;
    *) targets="$targets $target" ;;
  esac
done
sh toolchain/changelog-stamp.sh
# A word list on purpose: the targets are separate arguments.
# shellcheck disable=SC2086
cabal build -v0 --project-file="$native_project" --builddir="$native_build_dir" wiki-server:exe:wiki-server wiki-app:exe:wiki-app-prerender $targets
# Every program's path, before any suite starts: cabal is not run again
# once they run.
for suite in $suites; do
  program=$(cabal list-bin -v0 --project-file="$native_project" --builddir="$native_build_dir" "$(target_of "$suite")")
  eval "program_$(var_of "$suite")=\$program"
done
WIKI_SERVER=$(program_from_caller "${WIKI_SERVER:-}")
WIKI_PRERENDER=$(program_from_caller "${WIKI_PRERENDER:-}")
WIKI_SERVER=${WIKI_SERVER:-$(cabal list-bin -v0 --project-file="$native_project" --builddir="$native_build_dir" wiki-server:exe:wiki-server)}
WIKI_PRERENDER=${WIKI_PRERENDER:-$(cabal list-bin -v0 --project-file="$native_project" --builddir="$native_build_dir" wiki-app:exe:wiki-app-prerender)}
export WIKI_SERVER WIKI_PRERENDER
if [ "$#" -gt 0 ]; then
  WIKI_DEMO_DIR=$(path_from_caller "$1")
  export WIKI_DEMO_DIR
fi

# How many suites run at once: 1, one after another, unless asked.
jobs=${WIKI_SMOKE_JOBS:-1}
case $jobs in
  '' | *[!0-9]* | 0)
    printf 'WIKI_SMOKE_JOBS must be a positive number, not %s\n' "$jobs" >&2
    exit 2
    ;;
esac

# One part of the smoke test: a suite's built program, or the node
# programs.
run_part() {
  case $1 in
    node-programs) node toolchain/run-smoke-tests.mjs ;;
    *)
      eval "program=\$program_$(var_of "$1")"
      WIKI_SMOKE_PROGRAM=$program sh toolchain/smoke-suite.sh "$1"
      ;;
  esac
}

# A part's outcome, said once it has ended; $3, when given, is its log,
# printed first: in a group of its own in GitHub's log when the part
# passed, open when it failed.
failed=
report() {
  if [ "$2" = 0 ]; then
    if [ -n "${3:-}" ]; then
      [ -z "${GITHUB_ACTIONS:-}" ] || echo "::group::The smoke suite $1: passed"
      cat "$3"
      [ -z "${GITHUB_ACTIONS:-}" ] || echo "::endgroup::"
    fi
    printf 'The smoke suite %s: passed.\n' "$1"
  else
    [ -z "${3:-}" ] || cat "$3"
    [ -z "${GITHUB_ACTIONS:-}" ] || echo "::error title=The smoke suite $1 failed::exit status $2; its output is above"
    printf 'The smoke suite %s: failed (exit status %s).\n' "$1" "$2" >&2
    failed="$failed $1"
  fi
}

if [ "$jobs" -eq 1 ]; then
  for suite in $suites node-programs; do
    printf '\nThe smoke suite %s:\n' "$suite"
    status=0
    run_part "$suite" || status=$?
    report "$suite" "$status"
  done
else
  # Up to $jobs parts in the background, each its output and its status
  # in files of its own; when as many run as allowed, the oldest is waited
  # for and reported before the next starts, so the logs come in the
  # order of the list.
  logs=$(mktemp -d)
  trap 'rm -rf "$logs"' EXIT HUP INT TERM
  running=
  finish_oldest() {
    oldest=${running%% *}
    running=${running#"$oldest"}
    running=${running# }
    eval "pid=\$pid_$(var_of "$oldest")"
    wait "$pid" || true
    report "$oldest" "$(cat "$logs/$oldest.status" 2>/dev/null || echo "no status")" "$logs/$oldest.log"
  }
  count=0
  for suite in $suites node-programs; do
    if [ "$count" -ge "$jobs" ]; then
      finish_oldest
      count=$((count - 1))
    fi
    (
      status=0
      run_part "$suite" > "$logs/$suite.log" 2>&1 || status=$?
      echo "$status" > "$logs/$suite.status"
    ) &
    eval "pid_$(var_of "$suite")=\$!"
    running="${running:+$running }$suite"
    count=$((count + 1))
  done
  while [ -n "$running" ]; do
    finish_oldest
  done
fi
if [ -n "$failed" ]; then
  printf 'The smoke test failed:%s.\n' "$failed" >&2
  exit 1
fi
