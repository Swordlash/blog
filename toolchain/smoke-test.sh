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
# this builds first at -O0 in dist-newstyle/native-fast, and run one after
# the other: they are built with cabal in the same build directory. Every
# part runs whatever the others' outcome, and the command fails if any did.
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
sh toolchain/changelog-stamp.sh
cabal build -v0 --project-file="$native_project" --builddir="$native_build_dir" wiki-server:exe:wiki-server wiki-app:exe:wiki-app-prerender
WIKI_SERVER=$(program_from_caller "${WIKI_SERVER:-}")
WIKI_PRERENDER=$(program_from_caller "${WIKI_PRERENDER:-}")
WIKI_SERVER=${WIKI_SERVER:-$(cabal list-bin -v0 --project-file="$native_project" --builddir="$native_build_dir" wiki-server:exe:wiki-server)}
WIKI_PRERENDER=${WIKI_PRERENDER:-$(cabal list-bin -v0 --project-file="$native_project" --builddir="$native_build_dir" wiki-app:exe:wiki-app-prerender)}
export WIKI_SERVER WIKI_PRERENDER
if [ "$#" -gt 0 ]; then
  WIKI_DEMO_DIR=$(path_from_caller "$1")
  export WIKI_DEMO_DIR
fi
suites="demo passkeys server"
if [ -n "${WIKI_TEST_DATABASE_URL:-}" ]; then
  suites="$suites server-postgres"
else
  echo "The server's smoke suite on PostgreSQL: not run (WIKI_TEST_DATABASE_URL is not set)." >&2
fi
failed=
for suite in $suites; do
  sh toolchain/smoke-suite.sh "$suite" || failed="$failed $suite"
done
node toolchain/run-smoke-tests.mjs || failed="$failed node-programs"
if [ -n "$failed" ]; then
  printf 'The smoke test failed:%s.\n' "$failed" >&2
  exit 1
fi
