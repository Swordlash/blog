#!/bin/sh
# Run one of the smoke suites of wiki-smoke: native Haskell programs that
# drive the built page in headless Chromium through
# haskell-halogen-playwright, waiting on the page's program rather than on
# the clock (docs/PLAN.md, WP5.98).
#
#   sh toolchain/smoke-suite.sh screenshots [cabal test args...]      # npm run screenshots
#   sh toolchain/smoke-suite.sh waits [cabal test args...]            # npm run smoke-waits
#   sh toolchain/smoke-suite.sh demo [cabal test args...]             # part of npm run smoke-test
#   sh toolchain/smoke-suite.sh passkeys [cabal test args...]         # part of npm run smoke-test
#   sh toolchain/smoke-suite.sh server [cabal test args...]           # part of npm run smoke-test
#   sh toolchain/smoke-suite.sh server-postgres [cabal test args...]  # part of npm run smoke-test
#
# screenshots takes the README's screenshots into docs/screenshots (or the
# directory WIKI_SCREENSHOTS_DIR names); waits checks that the driver's
# waits hold on the wiki; demo is the demo's smoke test (wiki-smoke's
# demo/Main.hs says what it checks); passkeys the assistant's keys synced
# with real passkeys against a real wiki-server; server the server's smoke
# test, the server's build of the page served by a real wiki-server on
# SQLite (wiki-smoke's server/Main.hs says what it checks), and
# server-postgres the same on PostgreSQL. All drive the demo npm run
# build-wasm wrote in dist-newstyle/wasm/public/app, or the directory
# WIKI_DEMO_DIR names. Here the build is required (WIKI_SMOKE_REQUIRED=1):
# without it the suite fails rather than reporting its examples pending,
# as it does under a plain `cabal test`.
#
# passkeys and the server's suites also need wiki-server and
# wiki-app-prerender, built here natively (WIKI_SERVER and WIKI_PRERENDER
# name others). server-postgres needs a PostgreSQL server on which it may
# make two databases of its own: WIKI_TEST_DATABASE_URL names a database of
# it (postgres://user@host:port/postgres, with a query such as
# ?host=/run/postgresql when it is on a socket), with psql (WIKI_TEST_PSQL,
# else the PATH's) to make and drop them, and the pg_dump and pg_restore the
# server's backups run (WIKI_TEST_PG_DUMP and WIKI_TEST_PG_RESTORE, else the
# PATH's), as toolchain/ci-postgres.sh gives them in CI.
#
# The suites are built with the host GHC in the build directory of the
# smoke test's native programs: cabal-native-fast.project into
# dist-newstyle/native-fast, which CI's wasm job caches (NATIVE_PROJECT and
# NATIVE_BUILDDIR name others, as for toolchain/smoke-test.sh). The
# driver's variables pass through: HALOGEN_PLAYWRIGHT_THROTTLE=4 runs the
# suite with every page's processor slowed down four times (and, unless
# HALOGEN_PLAYWRIGHT_TIMEOUT says otherwise, each call may then take four
# times the plain 30 seconds),
# HALOGEN_PLAYWRIGHT_ARTIFACTS=<dir> keeps a failing example's screenshot,
# HALOGEN_PLAYWRIGHT_CONSOLE=1 prints what the pages log as it arrives, and
# HALOGEN_PLAYWRIGHT_HEADED=1 shows the browser.
#
# A path given in one of these variables may be relative to the directory
# this is run from: it is made absolute from there before the suite runs
# from wiki-smoke/ (toolchain/caller-paths.sh), and a program's bare name
# (WIKI_SERVER=wiki-server) is left for PATH.
#
# WIKI_SMOKE_PROGRAM names the suite's test program already built, which
# then runs from wiki-smoke/, as cabal runs it, without cabal: the
# arguments go to the program (hspec's options) rather than to cabal test.
# toolchain/smoke-test.sh builds every suite once and runs them so, one
# after another or, with WIKI_SMOKE_JOBS, side by side, where cabal itself
# must not run twice at once in one build directory.
# With WIKI_SUITE_TIMES=1 (CI), the suite runs through
# toolchain/ci-suite-time.sh, which times it, lists its five slowest
# examples and holds it to its budget.
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
# A native program, so built without the wasm toolchain's CC and friends,
# which CI's wasm job exports for every later command.
unset CC CXX LD AR NM RANLIB STRIP OBJCOPY OBJDUMP SIZE STRINGS

suite=${1:?usage: smoke-suite.sh <screenshots|waits|demo|passkeys|server|server-postgres> [cabal test args...]}
shift
name=smoke-$suite
case "$suite" in
  screenshots | waits | demo | passkeys | server) ;;
  server-postgres)
    suite=server
    WIKI_SMOKE_POSTGRES=1
    export WIKI_SMOKE_POSTGRES
    ;;
  *)
    printf 'No smoke suite %s: screenshots, waits, demo, passkeys, server or server-postgres\n' "$suite" >&2
    exit 2
    ;;
esac

# The suite runs in its package's directory, so every path is given to it
# absolute: the caller's from the caller's directory, the defaults from the
# repository's root, where this now is.
WIKI_SMOKE_REQUIRED=1
WIKI_DEMO_DIR=$(path_from_caller "${WIKI_DEMO_DIR:-}")
WIKI_DEMO_DIR=${WIKI_DEMO_DIR:-$(pwd)/dist-newstyle/wasm/public/app}
# The repository, whose web/src/tikz-letters.mjs the demo's suite reads.
WIKI_SOURCE_DIR=$(pwd)
export WIKI_SMOKE_REQUIRED WIKI_DEMO_DIR WIKI_SOURCE_DIR
if [ "$suite" = screenshots ]; then
  WIKI_SCREENSHOTS_DIR=$(path_from_caller "${WIKI_SCREENSHOTS_DIR:-}")
  WIKI_SCREENSHOTS_DIR=${WIKI_SCREENSHOTS_DIR:-$(pwd)/docs/screenshots}
  export WIKI_SCREENSHOTS_DIR
fi

# The driver's, and the PostgreSQL programs the server's suite runs.
for variable in HALOGEN_PLAYWRIGHT_ARTIFACTS; do
  eval "value=\${$variable:-}"
  [ -z "$value" ] || export "$variable=$(path_from_caller "$value")"
done
for variable in HALOGEN_PLAYWRIGHT_NODE WIKI_TEST_PSQL WIKI_TEST_PG_DUMP WIKI_TEST_PG_RESTORE; do
  eval "value=\${$variable:-}"
  [ -z "$value" ] || export "$variable=$(program_from_caller "$value")"
done

native_project=${NATIVE_PROJECT:-cabal-native-fast.project}
native_build_dir=${NATIVE_BUILDDIR:-dist-newstyle/native-fast}
if [ "$suite" = passkeys ] || [ "$suite" = server ]; then
  WIKI_SERVER=$(program_from_caller "${WIKI_SERVER:-}")
  WIKI_PRERENDER=$(program_from_caller "${WIKI_PRERENDER:-}")
  # SQLite runs keep their temporary data directories, even when a caller
  # has exported the address of a live deployment's database: the suites
  # give the server its database themselves.
  unset WIKI_DATABASE_URL WIKI_SMOKE_RESTORE_DATABASE_URL
  if [ -z "${WIKI_SERVER:-}" ] || [ -z "${WIKI_PRERENDER:-}" ]; then
    sh toolchain/changelog-stamp.sh
    cabal build -v0 --project-file="$native_project" --builddir="$native_build_dir" wiki-server:exe:wiki-server wiki-app:exe:wiki-app-prerender
  fi
  WIKI_SERVER=${WIKI_SERVER:-$(cabal list-bin -v0 --project-file="$native_project" --builddir="$native_build_dir" wiki-server:exe:wiki-server)}
  WIKI_PRERENDER=${WIKI_PRERENDER:-$(cabal list-bin -v0 --project-file="$native_project" --builddir="$native_build_dir" wiki-app:exe:wiki-app-prerender)}
  export WIKI_SERVER WIKI_PRERENDER
fi
program=$(program_from_caller "${WIKI_SMOKE_PROGRAM:-}")
if [ -n "$program" ]; then
  cd wiki-smoke
  if [ "${WIKI_SUITE_TIMES:-}" = 1 ]; then
    exec sh ../toolchain/ci-suite-time.sh "$name" "$program" "$@" --print-slow-items=5
  fi
  exec "$program" "$@"
fi
if [ "${WIKI_SUITE_TIMES:-}" = 1 ]; then
  exec sh toolchain/ci-suite-time.sh "$name" cabal test "wiki-smoke:test:wiki-smoke-$suite" --project-file="$native_project" --builddir="$native_build_dir" --test-show-details=direct "$@" --test-option=--print-slow-items=5
fi
exec cabal test "wiki-smoke:test:wiki-smoke-$suite" --project-file="$native_project" --builddir="$native_build_dir" --test-show-details=direct "$@"
