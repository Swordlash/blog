#!/bin/sh
# Bundle the islands' JavaScript libraries and styles: KaTeX, Mermaid,
# TikZJax and highlight.js, and fflate for the demo's zip files, from
# node_modules (npm ci first), with esbuild.
#
#   sh web/bundle.sh <output-dir>
#
# It writes:
#
#   islands.js       a classic script publishing globalThis.wikiIslands
#                    (web/src/islands.js), with KaTeX (and its mhchem, and
#                    the wiki's built-in macros, web/src/katex-macros.tex)
#                    and highlight.js in it,
#                    and globalThis.wikiArchive (web/src/archive.js), the zip
#                    files of the demo's export and import, with fflate;
#   islands/         Mermaid, as ES modules split by diagram type, which
#                    islands.js imports the first time it draws a diagram,
#                    and tikz.js (web/src/tikz.js), which it imports the
#                    first time it draws a TikZ picture;
#   tikzjax/         TikZJax's worker and TeX (from npm's @drgrice1/tikzjax,
#                    as published), which tikz.js runs, with the worker that
#                    starts it (web/src/tikz-worker.js);
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
# KaTeX's built-in macros (web/src/katex-macros.tex) go in as text, once
# KaTeX has been seen to read every one of them.
node web/check-macros.mjs
npx esbuild web/src/islands.js \
  --bundle --minify --format=iife --target=es2022 --log-level=warning \
  --loader:.tex=text \
  --outfile="$out_dir/islands.js"

# Mermaid loads each kind of diagram with a dynamic import of its own; split
# into chunks, a page with a flowchart fetches the flowchart's code only.
rm -rf "$out_dir/islands"
npx esbuild web/src/mermaid.js \
  --bundle --minify --format=esm --splitting --target=es2022 --log-level=warning \
  --chunk-names='chunks/[name]-[hash]' \
  --outdir="$out_dir/islands"

# TikZ's driver, outside Mermaid's split build so that it stays one file in
# islands/, where it finds TikZJax's files (../tikzjax/) by its own URL.
npx esbuild web/src/tikz.js \
  --bundle --minify --format=esm --target=es2022 --log-level=warning \
  --outfile="$out_dir/islands/tikz.js"

# TikZJax's files, copied as they are published: run-tex.js is its worker
# (TeX's WebAssembly runtime and dvi2html), tex.wasm.gz and core.dump.gz are
# TeX and the LaTeX format with TikZ loaded (6 MB, fetched by the first
# picture of a page and then from the browser's cache), tex_files/ the
# packages and TikZ libraries TeX may load, one file at a time, and fonts/
# the Computer Modern fonts its SVG is set in. Its own loader (tikzjax.js),
# the source maps and the TrueType copies of the fonts are not served.
tikzjax=node_modules/@drgrice1/tikzjax/dist
rm -rf "$out_dir/tikzjax"
mkdir -p "$out_dir/tikzjax"
cp -R "$tikzjax/run-tex.js" "$tikzjax/tex.wasm.gz" "$tikzjax/core.dump.gz" \
  "$tikzjax/tex_files" "$tikzjax/fonts" "$tikzjax/fonts.css" "$out_dir/tikzjax/"
cp web/src/tikz-worker.js "$out_dir/tikzjax/worker.js"
# TikZJax is free software under the GPL; say where its source is, beside it.
printf 'TikZJax %s, from npm'"'"'s @drgrice1/tikzjax, unmodified.\nLicence: GPL-3.0-or-later. Source: https://github.com/drgrice1/tikzjax\n' \
  "$(node -p 'require("./node_modules/@drgrice1/tikzjax/package.json").version')" >"$out_dir/tikzjax/NOTICE.txt"

# The fonts keep their names, since nothing caches them by hash yet.
npx esbuild web/src/islands.css \
  --bundle --minify --log-level=warning \
  --loader:.woff2=file --loader:.woff=file --loader:.ttf=file \
  --asset-names='fonts/[name]' \
  --outfile="$out_dir/islands.css"
