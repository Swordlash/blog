#!/bin/sh
# Build the wiki's browser application, wiki-app, and its pages: the
# maker's `build wasm` (maker/src/Maker/Build/Wasm.hs says what it writes
# and which variables it reads: WASM_PROJECT, WASM_BUILDDIR, WIKI_PUBLIC_DIR,
# WIKI_BACKEND, HALOGEN_BASE_PATH). Kept for the Dockerfile, which runs it
# by this name.
#
#   sh toolchain/build-wasm.sh [extra cabal args...]
set -eu
exec sh "$(dirname "$0")/maker.sh" build wasm "$@"
