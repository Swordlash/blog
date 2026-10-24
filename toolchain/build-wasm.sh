#!/bin/sh
# Build the wiki's browser application, wiki-app, to a browser-ready bundle.
#
#   sh toolchain/build-wasm.sh [extra cabal args...]
#
# Output lands in dist-newstyle/wasm/public/app/, emptied first so that nothing
# stale ships: app.wasm (size-optimised with wasm-opt), ghc_wasm_jsffi.js (the
# JSFFI glue for that binary), the page from web/ and the islands bundle
# web/bundle.sh writes (islands.js, islands.css, fonts/, islands/, tikzjax/). Its
# pages are then written by wiki-app-prerender, a native program built with
# the host GHC (into dist-newstyle/native) and run as
#
#   wiki-app-prerender web/index.html <output dir>
#
# to render the application natively into a page for each route of the demo
# (index.html, s/<space>/index.html, s/<space>/p/<page>/index.html, and
# 404.html for every other address), so that each shows before app.wasm has
# loaded. HALOGEN_BASE_PATH, if set, is the path the site is served under,
# written into each page's <base href>. Finally the sizes of what is served are
# reported, raw, gzipped and brotli'd (toolchain/compress.mjs).
#
# WASM_PROJECT and WASM_BUILDDIR choose the cabal project file and the build
# directory (default cabal-wasm.project and dist-newstyle/wasm); the output is
# then $WASM_BUILDDIR/public/app. `npm run build-wasm-opt` sets them to
# cabal-wasm-opt.project and dist-newstyle/wasm-opt for the -O2 production
# build toolchain/deploy-local.sh deploys, which is otherwise built exactly as
# this one. The prerender is a native program and is built the same way for
# both.
#
# Adapted from haskell-halogen's script of the same name, which builds one of
# its examples by name; here there is one application.
set -eu

cd "$(dirname "$0")/.."
. "$HOME/.ghc-wasm/env"

package=wiki-app
project=${WASM_PROJECT:-cabal-wasm.project}
build_dir=${WASM_BUILDDIR:-dist-newstyle/wasm}
public_dir=$build_dir/public/app

wasm_ghc=$(command -v wasm32-wasi-ghc)
wasm_ghc_pkg=$(command -v wasm32-wasi-ghc-pkg)
wasm_hsc2hs=$(command -v wasm32-wasi-hsc2hs)

# Cabal may reuse the host ghc-pkg from this cache when switching toolchains.
rm -f "$build_dir/cache/compiler"
# And it keeps the parsed project in cache/config, checked against the project
# file but not reliably against the files it imports: cabal-wasm-opt.project
# imports cabal-wasm.project, which imports cabal.project, and after a change
# to haskell-halogen's pin there the -O2 build went on building the old
# commit's sources, however often it ran. Reading the project afresh costs a
# few seconds.
rm -f "$build_dir/cache/config"

set -- \
  --project-file="$project" \
  --builddir="$build_dir" \
  --with-compiler="$wasm_ghc" \
  --with-hc-pkg="$wasm_ghc_pkg" \
  --with-hsc2hs="$wasm_hsc2hs" \
  "$package:exe:$package" "$@"

cabal build "$@"
# Again: in a build directory that did not exist before, the build above
# leaves the host ghc-pkg in this cache despite --with-hc-pkg, and list-bin
# then fails with "Version mismatch between ghc and ghc-pkg" (a second run
# would pass).
rm -f "$build_dir/cache/compiler"
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
# The page itself; web/bundle.sh and the sources it bundles (web/src/) are
# build inputs, not part of it. The bundle -- islands.js, islands.css, KaTeX's
# fonts, Mermaid's modules and TikZJax -- is written next to the page.
for entry in web/*; do
  case "$entry" in
    web/bundle.sh | web/src) ;;
    *) cp -R "$entry" "$public_dir/" ;;
  esac
done
sh web/bundle.sh "$public_dir"

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
# Mermaid's chunks are many and each is fetched only by a page with a diagram
# that needs it, so they are summed up rather than listed.
# The editor's CodeMirror (islands/editor.js) is fetched only by the editor.
# TikZJax's files are fetched only by a page with a picture: its worker and
# TeX (the .gz files are compressed already, and served as they are), and
# of tex_files/ and fonts/ only what a picture uses.
node toolchain/compress.mjs --no-write \
  $(find "$public_dir" -maxdepth 1 -type f \( -name '*.wasm' -o -name '*.js' -o -name '*.css' \) | sort) \
  "$public_dir/islands/mermaid.js" "$public_dir/islands/tikz.js" "$public_dir/islands/editor.js" \
  "$public_dir/tikzjax/run-tex.js"
printf '%s\t%s files, %s KiB\n' "$public_dir/islands/chunks/" \
  "$(find "$public_dir/islands/chunks" -type f | wc -l)" "$(du -sk "$public_dir/islands/chunks" | cut -f1)"
for file in tex.wasm.gz core.dump.gz; do
  printf '%s\t%s KiB\n' "$public_dir/tikzjax/$file" "$(du -k "$public_dir/tikzjax/$file" | cut -f1)"
done
for dir in tex_files fonts; do
  printf '%s\t%s files, %s KiB\n' "$public_dir/tikzjax/$dir/" \
    "$(find "$public_dir/tikzjax/$dir" -type f | wc -l)" "$(du -sk "$public_dir/tikzjax/$dir" | cut -f1)"
done

printf '\nBuilt %s in %s.\n' "$package" "$public_dir"
