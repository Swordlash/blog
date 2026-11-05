#!/bin/sh
# Build the hspec-halogen executable with the host GHC and print its path:
# the maker's `hspec-halogen`. Kept for CI's dependency step and
# toolchain/dev-test.sh, which run it by this name.
#
#   HSPEC_HALOGEN=$(sh toolchain/build-hspec-halogen.sh)
set -eu
exec sh "$(dirname "$0")/maker.sh" hspec-halogen
