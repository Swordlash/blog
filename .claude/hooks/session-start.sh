#!/bin/sh
# SessionStart, synchronous: install the toolchain in a Claude Code cloud
# session before it takes its first turn, so `cabal`, `ghc`, `wasm32-wasi-ghc`
# and Node 24 are there for the first command. On a container that already has
# them it takes a couple of seconds; on a fresh one about ten minutes, once,
# since the container is cached after the hook. Warming the cabal store, which
# takes much longer, is session-warm.sh's, in the background.
#
# Local sessions are left alone: a developer runs toolchain/bootstrap.sh by hand.
set -eu
[ "${CLAUDE_CODE_REMOTE:-}" = true ] || exit 0

root=${CLAUDE_PROJECT_DIR:-$(pwd)}

# The PATH lines go in first, as literal paths, so they hold for the session's
# commands even if the install below is cut short; the next session's run of
# this hook, or a `sh toolchain/bootstrap.sh` by hand, finishes it.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  sh "$root/toolchain/bootstrap.sh" env >>"$CLAUDE_ENV_FILE"
fi

exec sh "$root/toolchain/bootstrap.sh" toolchain
