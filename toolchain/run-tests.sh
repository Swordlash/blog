#!/bin/sh
# Run the test suites on both backends: natively, then on wasm (under Node,
# and in headless Chromium for browser suites; see test-wasm.sh).
set -eux

cd "$(dirname "$0")/.."

echo "Running native"
(
  # A native build must not see the wasm toolchain's CC and friends, should
  # the calling shell have sourced ~/.ghc-wasm/env.
  unset CC CXX LD AR NM RANLIB STRIP OBJCOPY OBJDUMP SIZE STRINGS
  sh toolchain/test-native.sh
)

echo "Running wasm"
sh toolchain/test-wasm.sh
