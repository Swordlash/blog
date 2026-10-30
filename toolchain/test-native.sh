#!/bin/sh
# The default runs every native suite. CI separates non-database tests and
# the server's two backends onto runners with their own CPU and memory.
set -eu
cd "$(dirname "$0")/.."
unset CC CXX LD AR NM RANLIB STRIP OBJCOPY OBJDUMP SIZE STRINGS
case ${WIKI_TEST_GROUP-all} in
  all | unit) target=all ;;
  sqlite | postgres) target=wiki-server:test:wiki-server-test ;;
  *) printf 'WIKI_TEST_GROUP must be all, unit, sqlite or postgres\n' >&2; exit 2 ;;
esac
exec cabal test "$target" --builddir=dist-newstyle/native "$@"
