#!/bin/sh
# The maker's command line and its terminal interface, built with the
# maker's own cabal project (maker/cabal.project) and run from the
# repository's root, with the toolchain's environment loaded as the npm
# scripts load it:
#
#   sh toolchain/maker.sh status                      the toolchain, component by component
#   sh toolchain/maker.sh toolchain install [TARGET…]  install components (system-packages,
#                                                     wasm-sysroot, wasm-ghc, node, chromium,
#                                                     fourmolu, store)
#   sh toolchain/maker.sh check native [OPTION…]      what the native build of wiki-server needs
#   sh toolchain/maker.sh deploy [OPTION…]            the deploy, with toolchain/deploy-local.sh's
#                                                     options; toolchain/deploy-local.sh runs it
#   sh toolchain/maker.sh tui                         the terminal interface
#   sh toolchain/maker.sh tui deploy [OPTION…]        the deploy's configuration wizard
#                                                     (toolchain/configure.sh runs it)
#   sh toolchain/maker.sh build native|wasm|wasm-opt [CABAL-ARG…]
#   sh toolchain/maker.sh test native|wasm|all [CABAL-ARG…]
#   sh toolchain/maker.sh serve [CABAL-ARG…]
#   sh toolchain/maker.sh --help
#
# The npm scripts run the builds and tests through it. WIKI_MAKER names a
# maker built elsewhere, which runs instead (the bootstrap's tests use it).
#
# GHC and cabal must be there first: toolchain/bootstrap.sh installs them
# (and runs the maker itself for the rest of the toolchain). The terminal
# interface links libtinfo, which `sh toolchain/bootstrap.sh native
# --with-wizard` installs on Debian.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# WIKI_SYSTEM_TOOLS (set by configure.sh --system-tools) keeps the
# machine's own tools: the bootstrap's environment then gives only the
# toolchain directory's variables, not the managed tools' PATH.
eval "$(sh "$ROOT/toolchain/bootstrap.sh" env ${WIKI_SYSTEM_TOOLS:+--system-tools})"
# The maker is a native program, and it computes the wasm build's
# environment itself: a shell that loaded ~/.ghc-wasm/env (CI exports it to
# every later step) must not hand it the cross compiler's CC and friends,
# which break cabal's native configuration.
unset CC CXX LD AR NM RANLIB STRIP OBJCOPY OBJDUMP SIZE STRINGS
exe=maker
if [ "${1:-}" = tui ]; then
  exe=maker-tui
  shift
  set -- --root "$ROOT" "$@"
fi
if [ "$exe" = maker ] && [ -n "${WIKI_MAKER:-}" ]; then
  cd "$ROOT"
  exec "$WIKI_MAKER" "$@"
fi
command -v cabal >/dev/null 2>&1 ||
  { printf 'maker: cabal is not on PATH; run sh toolchain/bootstrap.sh native first\n' >&2; exit 1; }
(cd "$ROOT/maker" && cabal build -v0 "exe:$exe")
binary=$(cd "$ROOT/maker" && cabal list-bin -v0 "exe:$exe")
cd "$ROOT"
exec "$binary" "$@"
