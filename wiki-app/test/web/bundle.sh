#!/bin/sh
# What the browser test runner loads before the suite, as the application's
# page has it: the islands' scripts and styles (the same bundle the page is
# served with), and the page's own style sheet, by which the editor shows its
# preview and hides its Markdown.
#
#   sh wiki-app/test/web/bundle.sh <output-dir>
#
# The runner (hspec-halogen's runner.mjs) runs this script before every run
# of the browser suite, with a new empty temporary directory as its argument,
# and deletes that directory after the run. toolchain/dev-test.sh runs it
# into the page of browser GHCi.
#
# The runner loads every script here into its page as a classic script, so
# what the bundle writes for the application's own page alone goes: the
# service worker (sw.js), which is no page's script, and the WASI shim
# (wasi-shim.js), a module the runner brings its own of.
#
# And the page's Content Security Policy, which a script puts on the
# runner's page before anything else runs (policy.mjs writes it as
# 0-policy.js), so that the suite runs under the policy the application has.
#
# Building all of that (web/bundle.sh: esbuild of every island, the TikZ
# patch, the licences) takes about ten seconds, and the output depends only
# on the inputs that inputs() below lists. So the finished bundle is kept in
# the build directory, in dist-newstyle/wasm/test-bundle/<digest>/, where the
# digest is taken of the contents of those inputs. A run whose inputs have
# the same digest copies the kept bundle instead of building it. Contents,
# not modification times: a git checkout changes the times of files and
# nothing else. The script prints one line saying whether it built or
# reused the bundle, and why it built.
#
# WIKI_TEST_BUNDLE_REBUILD=1 builds the bundle whatever the digest says, and
# keeps the new one. It is for a file under node_modules changed by hand:
# the digest sees the installed packages only through npm's record of them.
set -eu

out=${1:?usage: bundle.sh <output-dir>}
mkdir -p "$out"
out=$(cd "$out" && pwd)
cd "$(dirname "$0")/../../.."
keep=$(pwd)/dist-newstyle/wasm/test-bundle

say() { printf 'test bundle: %s\n' "$*" >&2; }

if command -v sha256sum >/dev/null 2>&1; then
  hasher=sha256sum
else
  hasher='shasum -a 256'
fi

# The inputs of the bundle, one line each, "<sha-256>  <name>", sorted by
# name. The digest of the bundle is the digest of these lines. A stale
# bundle is the one failure this cache must never have, so a file that may
# be read is in:
#
# - every file under web/: web/bundle.sh and web/check-macros.mjs, the
#   sources web/bundle.sh bundles (web/src/), the licences it copies
#   (web/licenses/), web/style.css, which this script copies, and
#   web/index.html, whose policy policy.mjs reads. The rest of web/
#   (index.js, the manifest) is not read today; it is in so that a script
#   that starts to read it is covered.
# - every file under wiki-app/test/web/: this script and policy.mjs.
# - package.json and package-lock.json: the bundled libraries' versions.
# - node_modules/.package-lock.json: npm's record of the packages
#   installed, which npm ci writes. The libraries bundled are the installed
#   ones, which differ from package-lock.json's until npm ci has run again.
#   Without this file the bundle is built and not kept (below).
# - Node's version: Node runs esbuild and the scripts.
# - HALOGEN_BASE_PATH, whether it is set, and its value. Nothing the bundle
#   runs reads it today (the prerender of npm run build-wasm does), but CI
#   sets it, and a bundle that some day writes the base path into a file
#   must not be reused under another base path.
inputs() {
  {
    find web wiki-app/test/web \( -type f -o -type l \) -print0
    for file in package.json package-lock.json node_modules/.package-lock.json; do
      if [ -e "$file" ]; then printf '%s\0' "$file"; fi
    done
  } | LC_ALL=C sort -z | xargs -0 $hasher
  value "node --version" "$(node --version)"
  value HALOGEN_BASE_PATH "${HALOGEN_BASE_PATH+set:}${HALOGEN_BASE_PATH:-}"
}

# One input that is not a file: the digest of its value, under its name in
# brackets.
value() {
  printf '%s  (%s)\n' "$(printf '%s' "$2" | $hasher | cut -d ' ' -f 1)" "$1"
}

# The names of the inputs that differ between two lists of inputs: changed,
# added or gone. At most three, then how many more.
changed() {
  awk '
    { name = substr($0, index($0, "  ") + 2) }
    FNR == NR { old[name] = $1; next }
    { if (!(name in old) || old[name] != $1) diff[++n] = name; delete old[name] }
    END {
      for (name in old) diff[++n] = name
      for (i = 1; i <= n && i <= 3; i++) printf "%s%s", (i > 1 ? ", " : ""), diff[i]
      if (n > 3) printf " and %d more", n - 3
    }
  ' "$1" "$2"
}

# A kept bundle is a directory named by its digest, holding:
#
#   bundle/   the bundle, as it is copied into the output directory;
#   inputs    the list of inputs it was built from, which the line of a
#             later build compares with to say what changed;
#   files     the list of the bundle's files with their digests, written
#             last, before the directory gets its digest's name.
#
# A directory under a digest's name is whole or absent, always. It gets
# that name by one rename of a finished build (the build happens under a
# name starting with a dot, which no lookup matches), and loses it by one
# rename out of the digests' names before anything in it is deleted
# (retire, below). A kill at any moment leaves at most a directory under a
# dotted name, which a later build removes.
#
# Two checks guard the copy, and both are wanted. The marker, files, makes
# a directory without it count as absent: none should exist, but one left
# by an older version of this script, or by a hand that deleted part of
# the cache, is retired and built again rather than copied. And the copy is
# compared with files after it is made, because a run beside this one (the
# shards of HSPEC_HALOGEN_JOBS, CI's on the owner's runner, two terminals)
# may retire the directory while it is being copied: the rename makes the
# rest of the copy fail or come out short. A copy that does not match is
# thrown away and the bundle built. So a run gets a whole bundle, kept or
# built, never a part of one.

# The names of the dot-directories, by what they hold: .build.* a build in
# progress, .reading.* a copy being checked, .retired.* a bundle being
# deleted, .inputs.* a run's list of inputs.
mkdir -p "$keep"
list=$(mktemp "$keep/.inputs.XXXXXX")
build='' reading=''
cleanup() { rm -rf "$list" "$list.after" ${build:+"$build"} ${reading:+"$reading"}; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# The list of a bundle's files, "<sha-256>  ./<path>", sorted.
files() {
  (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r $hasher)
}

# Take a kept bundle out of the digests' names, then delete it. Nothing to
# do when another run has retired it first.
retire() {
  if [ -e "$1" ]; then
    retired=$(mktemp -d "$keep/.retired.XXXXXX")
    mv "$1" "$retired/" 2>/dev/null || true
    rm -rf "$retired"
  fi
}

# Copy a kept bundle into the output directory, whole, or fail and copy
# nothing: the bundle is copied beside the kept ones first, and compared
# there with its list of files.
reuse() {
  reading=$(mktemp -d "$keep/.reading.XXXXXX") || return 1
  cp "$1/files" "$reading/files" 2>/dev/null || return 1
  cp -R "$1/bundle" "$reading/bundle" 2>/dev/null || return 1
  files "$reading/bundle" >"$reading/found" || return 1
  cmp -s "$reading/files" "$reading/found" || return 1
  cp -R "$reading/bundle/." "$out" || return 1
  rm -rf "$reading"
  reading=''
}

inputs >"$list"
key=$($hasher <"$list" | cut -d ' ' -f 1)
short=${key%"${key#????????????}"}
kept=$keep/$key

why=''
if [ -n "${WIKI_TEST_BUNDLE_REBUILD:-}" ]; then
  why='WIKI_TEST_BUNDLE_REBUILD is set'
elif [ ! -e node_modules/.package-lock.json ]; then
  why='node_modules/.package-lock.json is missing, so the installed packages are unknown (npm ci writes it); not kept'
elif [ -d "$kept" ] && [ ! -f "$kept/files" ]; then
  retire "$kept"
  why='the bundle kept for these inputs had no list of its files'
elif [ -d "$kept" ]; then
  if reuse "$kept"; then
    # Copied, not linked, since the output directory is written to after
    # this script (dev-test.sh copies into it), and a link would write
    # into the kept bundle. The times of the kept bundle and of its list
    # of inputs are renewed (-c: never made again if retired meanwhile):
    # the pruning below keeps the bundles used last, and the next build
    # names what changed since the list used last.
    touch -c "$kept" "$kept/inputs"
    say "reused $short (the inputs are unchanged)"
    exit 0
  fi
  # Either another run retired it during the copy, or it is damaged: in
  # the second case it must go, and in the first it is gone already.
  rm -rf "$reading"
  reading=''
  retire "$kept"
  why='the bundle kept for these inputs could not be copied whole (retired meanwhile, or damaged)'
fi
if [ -z "$why" ]; then
  last=$(ls -t "$keep"/*/inputs 2>/dev/null | head -n 1)
  if [ -n "$last" ]; then
    why="changed since the bundle used last: $(changed "$last" "$list")"
  else
    why='no bundle kept yet'
  fi
fi
say "building $short ($why)"

build=$(mktemp -d "$keep/.build.XXXXXX")
mkdir "$build/bundle"
sh web/bundle.sh "$build/bundle"
rm -f "$build/bundle/sw.js" "$build/bundle/wasi-shim.js"
cp web/style.css "$build/bundle/style.css"
node wiki-app/test/web/policy.mjs web/index.html "$build/bundle/0-policy.js"
cp -R "$build/bundle/." "$out"

# Kept only when the inputs did not change while the bundle was built (an
# edit in those ten seconds would put the new contents under the old
# digest), and only when node_modules can be told apart.
inputs >"$list.after"
if ! cmp -s "$list" "$list.after"; then
  say "not kept: the inputs changed while it was built ($(changed "$list" "$list.after"))"
  exit 0
fi
rm -f "$list.after"
if [ ! -e node_modules/.package-lock.json ]; then exit 0; fi
mv "$list" "$build/inputs"
files "$build/bundle" >"$build/files"
# A forced build replaces the bundle kept under its digest. Otherwise a
# directory there was kept by a run beside this one, and stays.
if [ -n "${WIKI_TEST_BUNDLE_REBUILD:-}" ]; then retire "$kept"; fi
# mv -T renames onto the digest's name, and fails rather than move the
# directory into one that a run beside this one has just kept.
if mv -T "$build" "$kept" 2>/dev/null; then
  build=''
else
  say "not kept: the build could not be renamed to $kept (kept meanwhile by a run beside this one?)"
fi

# The three bundles used last are kept (about 20 MB each), so that going
# back to a branch does not build again, and the rest retired. What killed
# runs left is removed: retired bundles at once (nothing reads them), and
# builds and copies an hour old or more (a run beside this one may still
# be making them).
ls -t "$keep" | tail -n +4 | while read -r old; do
  retire "$keep/$old"
done
find "$keep" -maxdepth 1 -name '.retired.*' -exec rm -rf {} + 2>/dev/null || true
find "$keep" -maxdepth 1 \( -name '.build.*' -o -name '.reading.*' -o -name '.inputs.*' \) -mmin +60 -exec rm -rf {} + 2>/dev/null || true
