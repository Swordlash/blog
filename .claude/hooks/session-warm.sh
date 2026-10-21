#!/bin/sh
# SessionStart, asynchronous: build the dependencies of cabal.project and
# cabal-wasm.project into the cabal store in the background, so a session is
# not held up for the half hour a cold store takes. It runs alongside
# session-start.sh and waits on toolchain/bootstrap.sh's lock until that one
# has installed the toolchain. A build started before it is done waits for, or
# shares, the store with it (cabal locks the store per package); to wait for
# it explicitly, run `sh toolchain/bootstrap.sh warm`, which takes the same lock
# and then finds nothing left to do.
set -eu
[ "${CLAUDE_CODE_REMOTE:-}" = true ] || exit 0

root=${CLAUDE_PROJECT_DIR:-$(pwd)}

# Tells Claude Code to run the rest in the background.
echo '{"async": true, "asyncTimeout": 3600000}'

exec sh "$root/toolchain/bootstrap.sh" warm
