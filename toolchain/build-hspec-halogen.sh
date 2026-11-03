#!/bin/sh
# Build the hspec-halogen executable with the host GHC and print its path.
#
#   HSPEC_HALOGEN=$(sh toolchain/build-hspec-halogen.sh)
#
# It is a native program -- cabal's test wrapper for browser suites and the
# opener for dev-test.sh -- so it is built without the wasm toolchain's CC and
# friends, which ~/.ghc-wasm/env and CI export for every later command.
set -eu

cd "$(dirname "$0")/.."
unset CC CXX LD AR NM RANLIB STRIP OBJCOPY OBJDUMP SIZE STRINGS
native_project=${NATIVE_PROJECT:-cabal-native-fast.project}
native_build_dir=${NATIVE_BUILDDIR:-dist-newstyle/native-fast}

# Cabal checks its cached project (cache/config) against the project file but
# not reliably against cabal.project, which it imports and which pins
# haskell-halogen: read it afresh, as build-wasm.sh does.
rm -f "$native_build_dir/cache/config"
cabal build -v0 hspec-halogen:exe:hspec-halogen --project-file="$native_project" --builddir="$native_build_dir" >&2
cabal list-bin -v0 hspec-halogen:exe:hspec-halogen --project-file="$native_project" --builddir="$native_build_dir"
