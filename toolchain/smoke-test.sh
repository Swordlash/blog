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
# Before them, toolchain/test-assistant.mjs: the writing assistant's
# providers over the real SDKs, against a fetch that answers as the
# providers' APIs do (it needs no build), and toolchain/test-tikz-letters.mjs:
# the error a TikZ picture shows for a letter TikZJax's fonts lack.
#
# After them, toolchain/test-passkeys.mjs: the assistant's keys synced with a
# real passkey, from Chromium's virtual authenticator, against a real
# wiki-server.
#
# The second needs wiki-server and wiki-app-prerender built natively, which
# this builds first (quickly, when npm run build-native has). It runs on
# SQLite, and then again on PostgreSQL when one is at hand:
# WIKI_TEST_DATABASE_URL names a database of a server on which this may make
# two databases of its own (postgres://user@host:port/postgres, with a query
# such as ?host=/run/postgresql when it is on a socket),
# with psql (WIKI_TEST_PSQL, else the PATH's) to make and drop them, and the
# pg_dump and pg_restore the server's backups run (WIKI_TEST_PG_DUMP and
# WIKI_TEST_PG_RESTORE, else the PATH's), as toolchain/ci-postgres.sh gives
# them in CI. Without it, the PostgreSQL run is reported as not run.
set -eu
cd "$(dirname "$0")/.."
if [ -r "$HOME/.wiki-toolchain/env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.wiki-toolchain/env"
fi
cabal build -v0 --builddir=dist-newstyle/native wiki-server:exe:wiki-server wiki-app:exe:wiki-app-prerender
node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON toolchain/test-assistant.mjs
node toolchain/test-tikz-letters.mjs
node toolchain/smoke-test.mjs "$@"
node toolchain/smoke-test-server.mjs "$@"
if [ -n "${WIKI_TEST_DATABASE_URL:-}" ]; then
  psql=${WIKI_TEST_PSQL:-psql}
  base=$WIKI_TEST_DATABASE_URL
  live=wiki_smoke_$$
  restored=wiki_smoke_$$_restored
  drop() { "$psql" "$base" -q -c "DROP DATABASE IF EXISTS $live WITH (FORCE)" -c "DROP DATABASE IF EXISTS $restored WITH (FORCE)" || true; }
  trap drop EXIT
  "$psql" "$base" -q -c "CREATE DATABASE $live" -c "CREATE DATABASE $restored"
  # The URLs of the two databases: the given one with its database's name
  # replaced, which is the last part of the path before any query.
  path=${base%%\?*}
  query=${base#"$path"}
  printf 'smoke-test: the server again, on PostgreSQL\n'
  WIKI_DATABASE_URL=${path%/*}/$live$query WIKI_SMOKE_RESTORE_DATABASE_URL=${path%/*}/$restored$query \
    WIKI_PG_DUMP=${WIKI_TEST_PG_DUMP:-} WIKI_PG_RESTORE=${WIKI_TEST_PG_RESTORE:-} \
    node toolchain/smoke-test-server.mjs "$@"
else
  printf 'smoke-test: the server on PostgreSQL: not run (set WIKI_TEST_DATABASE_URL)\n'
fi
node toolchain/test-passkeys.mjs "$@"
