#!/bin/sh
# Build the wiki's browser application, wiki-app, to a browser-ready bundle.
#
#   sh toolchain/build-wasm.sh [extra cabal args...]
#
# Output lands in dist-newstyle/wasm/public/app/, emptied first so that nothing
# stale ships: app.wasm (size-optimised with wasm-opt), ghc_wasm_jsffi.js (the
# JSFFI glue for that binary) and everything under web/. Its index.html is
# then written by wiki-app-prerender, a native program built with the host GHC
# (into dist-newstyle/native) and run as
#
#   wiki-app-prerender web/index.html <output dir>
#
# to render the application natively into the page (see Halogen.Static), so
# it shows before app.wasm has loaded. Finally the sizes of what is served are
# reported, raw, gzipped and brotli'd (toolchain/compress.mjs).
#
# Adapted from haskell-halogen's script of the same name, which builds one of
# its examples by name; here there is one application.
set -eu

cd "$(dirname "$0")/.."
. "$HOME/.ghc-wasm/env"

package=wiki-app
build_dir=dist-newstyle/wasm
public_dir=$build_dir/public/app

wasm_ghc=$(command -v wasm32-wasi-ghc)
wasm_ghc_pkg=$(command -v wasm32-wasi-ghc-pkg)
wasm_hsc2hs=$(command -v wasm32-wasi-hsc2hs)

# Cabal may reuse the host ghc-pkg from this cache when switching toolchains.
rm -f "$build_dir/cache/compiler"

set -- \
  --project-file=cabal-wasm.project \
  --builddir="$build_dir" \
  --with-compiler="$wasm_ghc" \
  --with-hc-pkg="$wasm_ghc_pkg" \
  --with-hsc2hs="$wasm_hsc2hs" \
  "$package:exe:$package" "$@"

cabal build "$@"
wasm_binary=$(cabal list-bin "$@")
wasm_libdir=$($wasm_ghc --print-libdir)

rm -rf "$public_dir"
mkdir -p "$public_dir"
node "$wasm_libdir/post-link.mjs" --input "$wasm_binary" --output "$public_dir/ghc_wasm_jsffi.js"
# The linker output carries a name section and debug info worth about a third
# of the file; stripping those and optimising for size roughly halves the
# binary and takes about a fifth off what is served gzipped. wasm-opt comes with
# ghc-wasm-meta's binaryen and leaves the imports and exports the JSFFI glue
# binds to untouched.
wasm-opt -Oz --strip-debug --strip-producers "$wasm_binary" -o "$public_dir/app.wasm"
cp -R web/. "$public_dir/"

# A native program, so built without the wasm toolchain's CC and friends,
# which ~/.ghc-wasm/env exported above (as toolchain/build-hspec-halogen.sh
# does).
prerender=$package-prerender
prerender_bin=$(
  unset CC CXX LD AR NM RANLIB STRIP OBJCOPY OBJDUMP SIZE STRINGS
  cabal build -v0 "$package:exe:$prerender" --builddir=dist-newstyle/native >&2
  cabal list-bin -v0 "$package:exe:$prerender" --builddir=dist-newstyle/native
)
"$prerender_bin" web/index.html "$public_dir"
printf 'Prerendered %s with %s.\n' "$public_dir/index.html" "$prerender"

# GitHub Pages compresses on the fly, so only report the sizes rather than
# writing precompressed copies next to the files.
node toolchain/compress.mjs --no-write \
  $(find "$public_dir" -type f \( -name '*.wasm' -o -name '*.js' -o -name '*.css' \) | sort)

printf '\nBuilt %s in %s.\n' "$package" "$public_dir"
