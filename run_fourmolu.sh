#!/bin/sh
# Format every Haskell source in the repository with fourmolu, with the
# settings in fourmolu.yaml (haskell-halogen's): in place by default, or with
# the fourmolu options given instead, as `npm run format-check` (and CI) runs
# it with `--mode check` to fail on anything it would change.
set -eu
cd "$(dirname "$0")"
[ "$#" -gt 0 ] || set -- --mode inplace
fourmolu "$@" wiki-core/src wiki-core/test wiki-core/test-html wiki-api/src wiki-api/test wiki-app/src wiki-app/app wiki-app/test wiki-server/app
