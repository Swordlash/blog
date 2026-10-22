#!/bin/sh
# Guard each npm entry point once. Serve calls the raw build script, so its
# rebuild does not repeat discovery, and npm arguments reach cabal unchanged.
# The test commands go through the same gate, so a shell that has not loaded
# ~/.wiki-toolchain/env runs them as it runs a build.
set -eu
cd "$(dirname "$0")/.."
command=${1:?usage: npm-command.sh <build-native|test-native|build-wasm|build-wasm-opt|test-wasm|test|dev-test|serve-wasm> [args...]}
shift
case $command in
  build-native | test-native | build-wasm | build-wasm-opt | test-wasm | test | dev-test | serve-wasm) ;;
  *) printf 'Unknown npm command: %s\n' "$command" >&2; exit 2 ;;
esac
# Bootstrap's environment only adjusts the native toolchain PATH. The wasm
# build script loads its own environment later, keeping wasm CC out of native
# builds. An already configured shell needs no generated env file.
if [ -r "$HOME/.wiki-toolchain/env" ]; then
  . "$HOME/.wiki-toolchain/env"
fi
# Older generated env files left managed directories behind incompatible
# tools already on PATH. Apply today's read-only directives as well, without
# rewriting the user's file or requiring another installation.
bootstrap_env=$(sh toolchain/bootstrap.sh env)
eval "$bootstrap_env"
sh toolchain/bootstrap.sh ready "$command"
case $command in
  build-native) exec cabal build all --builddir=dist-newstyle/native "$@" ;;
  test-native) exec cabal test all --builddir=dist-newstyle/native "$@" ;;
  build-wasm) exec sh toolchain/build-wasm.sh "$@" ;;
  # The -O2 production build, in a build directory of its own so that it and
  # the everyday build never invalidate each other (cabal-wasm-opt.project).
  build-wasm-opt)
    WASM_PROJECT=cabal-wasm-opt.project WASM_BUILDDIR=dist-newstyle/wasm-opt
    export WASM_PROJECT WASM_BUILDDIR
    exec sh toolchain/build-wasm.sh "$@" ;;
  test-wasm) exec sh toolchain/test-wasm.sh "$@" ;;
  test) exec sh toolchain/run-tests.sh "$@" ;;
  dev-test) exec sh toolchain/dev-test.sh "$@" ;;
  serve-wasm) exec sh toolchain/serve-wasm.sh "$@" ;;
esac
