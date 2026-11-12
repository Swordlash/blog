#!/bin/sh
# Run one of the smoke suites of wiki-smoke: native Haskell programs that
# drive the built page in headless Chromium through
# haskell-halogen-playwright, waiting on the page's program rather than on
# the clock (docs/PLAN.md, WP5.98).
#
#   sh toolchain/smoke-suite.sh screenshots [cabal test args...]   # npm run screenshots
#   sh toolchain/smoke-suite.sh waits [cabal test args...]         # npm run smoke-waits
#
# screenshots takes the README's screenshots into docs/screenshots (or the
# directory WIKI_SCREENSHOTS_DIR names); waits checks that the driver's
# waits hold on the wiki. Both drive the demo npm run build-wasm wrote in
# dist-newstyle/wasm/public/app, or the directory WIKI_DEMO_DIR names. Here
# the build is required (WIKI_SMOKE_REQUIRED=1): without it the suite fails
# rather than reporting its examples pending, as it does under a plain
# `cabal test`.
#
# The suites are built with the host GHC in the build directory of the
# smoke test's native programs: cabal-native-fast.project into
# dist-newstyle/native-fast, which CI's wasm job caches (NATIVE_PROJECT and
# NATIVE_BUILDDIR name others, as for toolchain/smoke-test.sh). The
# driver's variables pass through: HALOGEN_PLAYWRIGHT_THROTTLE=4 runs the
# suite with every page's processor slowed down four times,
# HALOGEN_PLAYWRIGHT_ARTIFACTS=<dir> keeps a failing example's screenshot,
# HALOGEN_PLAYWRIGHT_CONSOLE=1 prints what the pages log as it arrives, and
# HALOGEN_PLAYWRIGHT_HEADED=1 shows the browser.
set -eu
cd "$(dirname "$0")/.."
toolchain_home=${WIKI_TOOLCHAIN_HOME:-$HOME}
if [ -r "$toolchain_home/.wiki-toolchain/env" ]; then
  # shellcheck source=/dev/null
  . "$toolchain_home/.wiki-toolchain/env"
fi
# A native program, so built without the wasm toolchain's CC and friends,
# which CI's wasm job exports for every later command.
unset CC CXX LD AR NM RANLIB STRIP OBJCOPY OBJDUMP SIZE STRINGS

suite=${1:?usage: smoke-suite.sh <screenshots|waits> [cabal test args...]}
shift
case "$suite" in
  screenshots | waits) ;;
  *)
    printf 'No smoke suite %s: screenshots or waits\n' "$suite" >&2
    exit 2
    ;;
esac

# The suite runs in its package's directory, so the directories are given
# to it absolute.
absolute() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$(pwd)" "$1" ;;
  esac
}
WIKI_SMOKE_REQUIRED=1
WIKI_DEMO_DIR=$(absolute "${WIKI_DEMO_DIR:-dist-newstyle/wasm/public/app}")
export WIKI_SMOKE_REQUIRED WIKI_DEMO_DIR
if [ "$suite" = screenshots ]; then
  WIKI_SCREENSHOTS_DIR=$(absolute "${WIKI_SCREENSHOTS_DIR:-docs/screenshots}")
  export WIKI_SCREENSHOTS_DIR
fi

native_project=${NATIVE_PROJECT:-cabal-native-fast.project}
native_build_dir=${NATIVE_BUILDDIR:-dist-newstyle/native-fast}
exec cabal test "wiki-smoke:test:wiki-smoke-$suite" --project-file="$native_project" --builddir="$native_build_dir" --test-show-details=direct "$@"
