#!/bin/sh
# Guard each npm entry point once. Serve calls the raw build script, so its
# rebuild does not repeat discovery, and npm arguments reach cabal unchanged.
set -eu
cd "$(dirname "$0")/.."
command=${1:?usage: npm-command.sh <build-native|build-wasm|serve-wasm> [args...]}
shift
case $command in
  build-native | build-wasm | serve-wasm) ;;
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
  build-wasm) exec sh toolchain/build-wasm.sh "$@" ;;
  serve-wasm) exec sh toolchain/serve-wasm.sh "$@" ;;
esac
