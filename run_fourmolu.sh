#!/bin/sh
# Format every Haskell source in the repository with fourmolu, in place, with
# the settings in fourmolu.yaml (haskell-halogen's).
set -eu
cd "$(dirname "$0")"
fourmolu -i wiki-core/src wiki-core/test wiki-api/src wiki-api/test wiki-app/src wiki-app/app wiki-app/test wiki-server/app
