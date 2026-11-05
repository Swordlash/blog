#!/bin/sh
# The native test suites of WIKI_TEST_GROUP (all, unit, sqlite or
# postgres; unset is all): the maker's `test native`, with cabal's
# arguments after its own.
set -eu
exec sh "$(dirname "$0")/maker.sh" test native "$@"
