---
pr: 0
title: The builds and tests run through the maker
---

## New features

`npm run build-wasm`, `build-native`, `test-native`, `test-wasm` and the
others now hand their work to the maker, which also takes them directly.
A rebuild of the browser application skips wasm-opt when the compiled
program has not changed, and the JavaScript bundle when its sources and
packages have not:

```sh
sh toolchain/maker.sh build wasm
sh toolchain/maker.sh test native --test-options='--match "/Slug/"'
```

## Other changes

`toolchain/test-wasm.sh`, `toolchain/run-tests.sh` and
`toolchain/serve-wasm.sh` are gone: use `npm run test-wasm`, `npm run test`
and `npm run serve`. `toolchain/build-wasm.sh`, `toolchain/test-native.sh`
and `toolchain/build-hspec-halogen.sh` remain, and run the maker.
