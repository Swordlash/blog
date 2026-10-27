#!/bin/sh
# Run a command beside a PostgreSQL server of its own, made for it and
# thrown away after it, with WIKI_TEST_POSTGRES naming the server, as the
# server's tests read it (wiki-server/test/Test/Storage/Persistent.hs):
#
#   sh toolchain/with-postgres.sh npm run test-native
#   sh toolchain/with-postgres.sh cabal test wiki-server --builddir=dist-newstyle/native \
#     --test-options='--match "/persistent/"'
#
# The server listens on a unix socket in its own temporary directory and on
# no TCP port, so two runs never meet, and trusts whoever connects through
# that socket. It needs PostgreSQL's server programs (initdb, pg_ctl), found
# with pg_config, or under /usr/lib/postgresql (Debian's postgresql package);
# CI starts a PostgreSQL service container instead and sets the variable
# itself (.github/workflows/build.yml). PostgreSQL refuses to run as root:
# as root, the server runs as the postgres user, which owns its directory.
set -eu

bindir=
if command -v pg_config >/dev/null 2>&1 && [ -x "$(pg_config --bindir)/initdb" ]; then
  bindir=$(pg_config --bindir)
else
  for dir in /usr/lib/postgresql/*/bin; do
    [ -x "$dir/initdb" ] && bindir=$dir
  done
fi
if [ -z "$bindir" ]; then
  echo "with-postgres: no PostgreSQL server programs (initdb, pg_ctl) found; install PostgreSQL's server (Debian: postgresql)" >&2
  exit 1
fi

dir=$(mktemp -d "${TMPDIR:-/tmp}/wiki-postgres.XXXXXX")
as=
if [ "$(id -u)" = 0 ]; then
  chown postgres "$dir"
  as="runuser -u postgres --"
fi

stop() {
  $as "$bindir/pg_ctl" -D "$dir/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$dir"
}
trap stop EXIT INT TERM

$as "$bindir/initdb" -D "$dir/data" -U postgres --auth=trust --encoding=UTF8 --locale=C.UTF-8 >"$dir/initdb.log" 2>&1 \
  || { cat "$dir/initdb.log" >&2; exit 1; }
$as "$bindir/pg_ctl" -D "$dir/data" -l "$dir/server.log" -w \
  -o "-c listen_addresses='' -k $dir -c fsync=off" start >/dev/null \
  || { cat "$dir/server.log" >&2; exit 1; }

WIKI_TEST_POSTGRES="host=$dir port=5432 user=postgres dbname=postgres"
export WIKI_TEST_POSTGRES
"$@"
