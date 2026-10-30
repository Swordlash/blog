#!/bin/sh
# The smoke test, in both its modes, on the build npm run build-wasm wrote:
#
#   npm run smoke-test [-- dir]
#
# 1. toolchain/smoke-test.mjs: the serverless demo, as a static host serves
#    it (the build's own pages).
# 2. toolchain/smoke-test-server.mjs: the same app.wasm with the server's
#    page (wiki-app-prerender --server), served by a real wiki-server on a
#    temporary data directory, with an administrator made on its console who
#    signs in, driven end to end.
#
# Alongside them, toolchain/test-assistant.mjs: the writing assistant's
# providers over the real SDKs, against a fetch that answers as the
# providers' APIs do (it needs no build), and toolchain/test-tikz-letters.mjs:
# the error a TikZ picture shows for a letter TikZJax's fonts lack.
#
# Alongside them, toolchain/test-passkeys.mjs: the assistant's keys synced with a
# real passkey, from Chromium's virtual authenticator, against a real
# wiki-server.
#
# The second needs wiki-server and wiki-app-prerender built natively, which
# this builds first at -O0 in dist-newstyle/native-fast. It runs on
# SQLite, and also on PostgreSQL when one is at hand:
# WIKI_TEST_DATABASE_URL names a database of a server on which this may make
# two databases of its own (postgres://user@host:port/postgres, with a query
# such as ?host=/run/postgresql when it is on a socket),
# with psql (WIKI_TEST_PSQL, else the PATH's) to make and drop them, and the
# pg_dump and pg_restore the server's backups run (WIKI_TEST_PG_DUMP and
# WIKI_TEST_PG_RESTORE, else the PATH's), as toolchain/ci-postgres.sh gives
# them in CI. Without it, the PostgreSQL run is reported as not run.
# Independent programs run two at a time (SMOKE_JOBS selects another limit).
# State changes within a program keep their original order.
set -eu
cd "$(dirname "$0")/.."
if [ -r "$HOME/.wiki-toolchain/env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.wiki-toolchain/env"
fi
native_project=${NATIVE_PROJECT:-cabal-native-fast.project}
native_build_dir=${NATIVE_BUILDDIR:-dist-newstyle/native-fast}
cabal build -v0 --project-file="$native_project" --builddir="$native_build_dir" wiki-server:exe:wiki-server wiki-app:exe:wiki-app-prerender
WIKI_SERVER=${WIKI_SERVER:-$(cabal list-bin -v0 --project-file="$native_project" --builddir="$native_build_dir" wiki-server:exe:wiki-server)}
WIKI_PRERENDER=${WIKI_PRERENDER:-$(cabal list-bin -v0 --project-file="$native_project" --builddir="$native_build_dir" wiki-app:exe:wiki-app-prerender)}
export WIKI_SERVER WIKI_PRERENDER
exec node toolchain/run-smoke-tests.mjs "$@"
