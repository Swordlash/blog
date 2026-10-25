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
# The second needs wiki-server and wiki-app-prerender built natively, which
# this builds first (quickly, when npm run build-native has).
set -eu
cd "$(dirname "$0")/.."
if [ -r "$HOME/.wiki-toolchain/env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.wiki-toolchain/env"
fi
cabal build -v0 --builddir=dist-newstyle/native wiki-server:exe:wiki-server wiki-app:exe:wiki-app-prerender
node toolchain/smoke-test.mjs "$@"
node toolchain/smoke-test-server.mjs "$@"
