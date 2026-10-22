#!/bin/sh
# Bundle the islands' JavaScript libraries and styles: KaTeX, Mermaid and
# highlight.js, from node_modules (npm ci first), with esbuild.
#
#   sh web/bundle.sh <output-dir>
#
# It writes:
#
#   islands.js       a classic script publishing globalThis.wikiIslands
#                    (web/src/islands.js), with KaTeX and highlight.js in it;
#   islands/         Mermaid, as ES modules split by diagram type, which
#                    islands.js imports the first time it draws a diagram;
#   islands.css      KaTeX's stylesheet and the islands' own (web/src/islands.css);
#   fonts/           KaTeX's fonts, where islands.css's url()s point.
#
# toolchain/build-wasm.sh runs it into the page it builds, and the browser
# test suite's wiki-app/test/web/bundle.sh into the test page.
set -eu

cd "$(dirname "$0")/.."

out_dir=${1:?usage: bundle.sh <output-dir>}
mkdir -p "$out_dir"

# A classic script, not a module: the page and the browser test runner load it
# with a plain <script>, before the application, so that the global is there
# by the time the application first fills an island.
npx esbuild web/src/islands.js \
  --bundle --minify --format=iife --target=es2022 --log-level=warning \
  --outfile="$out_dir/islands.js"

# Mermaid loads each kind of diagram with a dynamic import of its own; split
# into chunks, a page with a flowchart fetches the flowchart's code only.
rm -rf "$out_dir/islands"
npx esbuild web/src/mermaid.js \
  --bundle --minify --format=esm --splitting --target=es2022 --log-level=warning \
  --chunk-names='chunks/[name]-[hash]' \
  --outdir="$out_dir/islands"

# The fonts keep their names, since nothing caches them by hash yet.
npx esbuild web/src/islands.css \
  --bundle --minify --log-level=warning \
  --loader:.woff2=file --loader:.woff=file --loader:.ttf=file \
  --asset-names='fonts/[name]' \
  --outfile="$out_dir/islands.css"
