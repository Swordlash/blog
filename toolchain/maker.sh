#!/bin/sh
# The maker's command line and its terminal interface, built with the
# maker's own cabal project (maker/cabal.project) and run from the
# repository's root, with the toolchain's environment loaded as the npm
# scripts load it:
#
#   sh toolchain/maker.sh status                      the toolchain, component by component
#   sh toolchain/maker.sh toolchain install [TARGET…]  install components (wasm-sysroot,
#                                                     wasm-ghc, node, chromium, fourmolu, store)
#   sh toolchain/maker.sh tui                         the terminal interface
#   sh toolchain/maker.sh --help
#
# GHC and cabal must be there first: toolchain/bootstrap.sh installs them
# (and runs the maker itself for the rest of the toolchain). The terminal
# interface links libtinfo, which `sh toolchain/bootstrap.sh native
# --with-wizard` installs on Debian.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sh "$ROOT/toolchain/bootstrap.sh" env)"
exe=maker
if [ "${1:-}" = tui ]; then
  exe=maker-tui
  shift
  set -- --root "$ROOT"
fi
command -v cabal >/dev/null 2>&1 ||
  { printf 'maker: cabal is not on PATH; run sh toolchain/bootstrap.sh native first\n' >&2; exit 1; }
(cd "$ROOT/maker" && cabal build -v0 "exe:$exe")
binary=$(cd "$ROOT/maker" && cabal list-bin -v0 "exe:$exe")
cd "$ROOT"
exec "$binary" "$@"
