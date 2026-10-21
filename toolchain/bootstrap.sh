#!/bin/sh
# Install the toolchain this repository builds with, and warm the cabal store.
#
#   sh toolchain/bootstrap.sh             # toolchain, then warm the store
#   sh toolchain/bootstrap.sh toolchain   # the toolchain only
#   sh toolchain/bootstrap.sh warm        # the toolchain if missing, then warm
#   sh toolchain/bootstrap.sh env         # print the PATH lines a shell needs
#
# It installs, on x86_64 Linux:
#
#   - ghcup (into ~/.ghcup, unless one is already on PATH), and through it
#     GHC $GHC_VERSION and cabal $CABAL_VERSION, both made the default;
#   - ghc-wasm-meta at $GHC_WASM_META_REV (into ~/.ghc-wasm: wasi-sdk,
#     binaryen, wasmtime and its own Node), and through ghcup the cross compiler
#     wasm32-wasi-ghc-$WASM_GHC_VERSION, exactly as haskell-halogen's CI does;
#   - Node $NODE_VERSION, into ~/.wiki-toolchain/node;
#   - Chromium's headless shell for Playwright, the revision the project's
#     Playwright (package-lock.json, or $PLAYWRIGHT_VERSION before there is
#     one) asks for, into $PLAYWRIGHT_BROWSERS_PATH or Playwright's default;
#   - the Debian packages these need, if they are missing and it can (root or
#     password-less sudo); otherwise it names them and stops.
#
# Then, for each of cabal.project and cabal-wasm.project that exists in the
# repository, it runs `cabal build all --only-dependencies` with the flags
# toolchain/build-wasm.sh-style scripts use, so the first real build only
# compiles this repository's own packages.
#
# Every step checks for itself and is skipped when what it installs is already
# there and works, so a run that was interrupted halfway is repaired by the next
# one, and a run with nothing to do prints one line per phase and takes a couple
# of seconds. Two runs at once (the two SessionStart hooks in .claude/, or a
# developer and a hook) take turns on a lock rather than racing: running this
# script while a background run is busy waits for it, which is also how to wait
# for the toolchain in a session whose hook is still working.
#
# Commands' own output goes to ~/.wiki-toolchain/bootstrap.log (appended, one
# header per run); the terminal gets a line per step, and on a failure the end
# of the log.
#
# A developer runs it by hand the same way. It changes ghcup's default GHC and
# cabal to the pinned ones, and leaves the shell's PATH alone: afterwards, put
#
#   . ~/.wiki-toolchain/env
#
# in your shell profile (or run it in the shell you build from), and source
# ~/.ghc-wasm/env where a script needs the wasm tools, as the build scripts do.
set -eu

# Pins. They must match haskell-halogen's .github/workflows/build.yml
# (GHC_VERSION, CABAL_VERSION, WASM_GHC_VERSION, GHC_WASM_META_REV) and the
# with-compiler of its cabal-wasm.project, for the haskell-halogen commit
# cabal.project pins: bump them together with that pin.
GHC_VERSION=9.14.1
CABAL_VERSION=3.16.1.0
WASM_GHC_VERSION=9.14.1.20260731
GHC_WASM_META_REV=358ea50b8496a69da6ce375c0c58bc049dbcb92d
GHC_WASM_FLAVOUR=9.14
# Not pinned by haskell-halogen: the ghcup used when none is installed, the Node
# the npm scripts and test runners use (haskell-halogen's need 24 or later), and
# the Playwright whose Chromium is installed until package-lock.json names one
# (haskell-halogen's package-lock.json).
GHCUP_VERSION=0.2.6.2
GHCUP_SHA256=9ed5da5449b48043a0d17e767c05d2ef585e25a639bb934329496c6d2fad9cf8
NODE_VERSION=24.21.0
NODE_SHA256=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6
PLAYWRIGHT_VERSION=1.63.0

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE=$HOME/.wiki-toolchain
LOG=$STATE/bootstrap.log
WASM_PREFIX=$HOME/.ghc-wasm
META_DIR=$STATE/ghc-wasm-meta-$GHC_WASM_META_REV
NODE_DIR=$STATE/node-v$NODE_VERSION-linux-x64

mode=${1:-all}
case $mode in
  all | toolchain | warm | env) ;;
  *)
    printf 'usage: %s [all|toolchain|warm|env]\n' "$0" >&2
    exit 2
    ;;
esac

# Where ghcup puts its symlinks: the bin directory of a ghcup already on PATH,
# or the default one this script installs into.
if command -v ghcup >/dev/null 2>&1; then
  GHCUP=$(command -v ghcup)
  GHCUP_BIN=$("$GHCUP" whereis bindir)
else
  GHCUP_BIN=${GHCUP_INSTALL_BASE_PREFIX:-$HOME}/.ghcup/bin
  GHCUP=$GHCUP_BIN/ghcup
fi

# The lines a shell needs to find ghcup's tools and this Node first. Written as
# literal paths so they are right whenever they are read, even before the
# install they point at has finished.
env_lines() {
  cat <<EOF
# Written by toolchain/bootstrap.sh: Node $NODE_VERSION, then ghcup's GHC and cabal, ahead of the rest of PATH.
case ":\$PATH:" in *":$GHCUP_BIN:"*) ;; *) PATH="$GHCUP_BIN:\$PATH" ;; esac
case ":\$PATH:" in *":$STATE/node/bin:"*) ;; *) PATH="$STATE/node/bin:\$PATH" ;; esac
export PATH
EOF
}

if [ "$mode" = env ]; then
  env_lines
  exit 0
fi

mkdir -p "$STATE"
PATH=$STATE/node/bin:$GHCUP_BIN:$PATH
export PATH

say() {
  printf 'bootstrap: %s\n' "$*"
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

fail() {
  printf 'bootstrap: %s failed; the end of %s:\n' "$1" "$LOG" >&2
  tail -n 40 "$LOG" >&2
  exit 1
}

# Run a command with its output in the log; on failure, show the log's end.
run() {
  step=$1
  shift
  printf '+ %s\n' "$*" >>"$LOG"
  "$@" >>"$LOG" 2>&1 || fail "$step"
}

fetch() {
  curl --fail --location --retry 5 --silent --show-error --output "$2" "$1"
}

check_sha256() {
  printf '%s  %s\n' "$2" "$1" | sha256sum --check --status
}

# Take a lock for the rest of a subshell, saying so if someone else holds it.
# Without flock (not Linux) runs are simply not serialised.
lock() {
  command -v flock >/dev/null 2>&1 || return 0
  if ! flock -n 9; then
    say "another bootstrap holds $1; waiting for it (its progress is in $LOG)"
    flock 9
  fi
}

# --- Toolchain --------------------------------------------------------------

# Debian packages: a C toolchain (GHC links with it), GMP's development files
# (native programs link libgmp), and what ghc-wasm-meta's setup.sh runs.
system_packages() {
  missing=
  if command -v dpkg-query >/dev/null 2>&1; then
    for pkg in build-essential curl git jq unzip xz-utils zstd libgmp-dev; do
      if ! dpkg-query -W -f '${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
        missing="$missing $pkg"
      fi
    done
  else
    for cmd in cc make curl git jq unzip xz unzstd; do
      command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
      say "missing commands:$missing (and GHC needs GMP's development files); install them and run this again"
      exit 1
    fi
    return 0
  fi
  [ -n "$missing" ] || return 0
  if [ "$(id -u)" = 0 ]; then
    sudo=
  elif sudo -n true 2>/dev/null; then
    sudo=sudo
  else
    say "missing Debian packages:$missing; install them (sudo apt-get install$missing) and run this again"
    exit 1
  fi
  say "installing Debian packages:$missing"
  # A failing third-party source should not stop the Ubuntu archive's lists from
  # updating; the install below fails by itself if what it needs is not there.
  printf '+ apt-get update\n' >>"$LOG"
  $sudo env DEBIAN_FRONTEND=noninteractive apt-get update >>"$LOG" 2>&1 || true
  # shellcheck disable=SC2086
  run "installing Debian packages" $sudo env DEBIAN_FRONTEND=noninteractive \
    apt-get install --yes --no-install-recommends $missing
}

install_ghcup() {
  if "$GHCUP" --version >/dev/null 2>&1; then
    return 0
  fi
  say "installing ghcup $GHCUP_VERSION into $GHCUP_BIN"
  mkdir -p "$GHCUP_BIN"
  tmp=$GHCUP.download
  run "downloading ghcup" fetch \
    "https://downloads.haskell.org/~ghcup/$GHCUP_VERSION/x86_64-linux-ghcup-$GHCUP_VERSION" "$tmp"
  check_sha256 "$tmp" "$GHCUP_SHA256" || fail "checking ghcup's checksum"
  chmod 755 "$tmp"
  mv "$tmp" "$GHCUP"
}

# A tool counts as installed when its versioned binary runs and says the pinned
# version. ghcup creates that link once an install has finished, so a directory
# an interrupted install left behind does not count, and is removed first.
#
#   ghcup_tool <tool> <ghcup version> <binary> <version it reports> <install command...>
ghcup_tool() {
  tool=$1 version=$2 binary=$3 reports=$4
  shift 4
  if [ "$("$GHCUP_BIN/$binary" --numeric-version 2>/dev/null || true)" != "$reports" ]; then
    say "installing $tool $version with ghcup"
    if "$GHCUP" whereis "$tool" "$version" >/dev/null 2>&1; then
      run "removing a broken $tool $version" "$GHCUP" rm "$tool" "$version"
    fi
    run "installing $tool $version" "$@"
  fi
}

install_native() {
  ghcup_tool ghc "$GHC_VERSION" "ghc-$GHC_VERSION" "$GHC_VERSION" \
    "$GHCUP" install ghc "$GHC_VERSION"
  if [ "$(ghc --numeric-version 2>/dev/null || true)" != "$GHC_VERSION" ]; then
    run "making GHC $GHC_VERSION the default" "$GHCUP" set ghc "$GHC_VERSION"
  fi
  ghcup_tool cabal "$CABAL_VERSION" "cabal-$CABAL_VERSION" "$CABAL_VERSION" \
    "$GHCUP" install cabal "$CABAL_VERSION"
  if [ "$(cabal --numeric-version 2>/dev/null || true)" != "$CABAL_VERSION" ]; then
    run "making cabal $CABAL_VERSION the default" "$GHCUP" set cabal "$CABAL_VERSION"
  fi
}

# ghc-wasm-meta's setup.sh starts by deleting ~/.ghc-wasm, so the stamp it is
# given at the end only exists after a complete run, and only for this revision.
install_wasm_sysroot() {
  stamp=$WASM_PREFIX/.bootstrap-$GHC_WASM_META_REV
  if [ ! -f "$META_DIR/ghcup-wasm-0.0.9.yaml" ]; then
    say "fetching ghc-wasm-meta $GHC_WASM_META_REV"
    rm -rf "$META_DIR" "$META_DIR.tmp"
    mkdir -p "$META_DIR.tmp"
    run "downloading ghc-wasm-meta" fetch \
      "https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta/-/archive/$GHC_WASM_META_REV/ghc-wasm-meta-$GHC_WASM_META_REV.tar.gz" \
      "$META_DIR.tmp.tar.gz"
    run "unpacking ghc-wasm-meta" tar xzf "$META_DIR.tmp.tar.gz" --strip-components=1 --directory "$META_DIR.tmp"
    rm -f "$META_DIR.tmp.tar.gz"
    mv "$META_DIR.tmp" "$META_DIR"
  fi
  if [ ! -f "$stamp" ] || [ ! -x "$WASM_PREFIX/add_to_github_path.sh" ]; then
    say "installing the wasm sysroot into $WASM_PREFIX (wasi-sdk, binaryen, wasmtime, Node)"
    run "installing the wasm sysroot" env SKIP_GHC=1 FLAVOUR="$GHC_WASM_FLAVOUR" bash "$META_DIR/setup.sh"
    touch "$stamp"
  fi
}

# The cross compiler, installed from ghc-wasm-meta's ghcup metadata with the
# configure arguments its env file exports, as haskell-halogen's CI does.
install_wasm_ghc() {
  ghcup_tool ghc "wasm32-wasi-$WASM_GHC_VERSION" "wasm32-wasi-ghc-$WASM_GHC_VERSION" "$WASM_GHC_VERSION" \
    ghcup_wasm_install
  if [ "$("$GHCUP_BIN/wasm32-wasi-ghc" --numeric-version 2>/dev/null || true)" != "$WASM_GHC_VERSION" ]; then
    run "making wasm32-wasi-ghc $WASM_GHC_VERSION the default" \
      "$GHCUP" set ghc "wasm32-wasi-$WASM_GHC_VERSION"
  fi
}

# In a subshell: ~/.ghc-wasm/env exports CC and friends for the wasm target,
# which the native steps after this one must not see.
ghcup_wasm_install() {
  (
    # shellcheck source=/dev/null
    . "$WASM_PREFIX/env"
    # shellcheck disable=SC2086
    "$GHCUP" -s "file://$META_DIR/ghcup-wasm-0.0.9.yaml" \
      install ghc "wasm32-wasi-$WASM_GHC_VERSION" --set -- $CONFIGURE_ARGS
  )
}

install_node() {
  if [ "$("$NODE_DIR/bin/node" --version 2>/dev/null || true)" != "v$NODE_VERSION" ]; then
    say "installing Node $NODE_VERSION into $NODE_DIR"
    rm -rf "$NODE_DIR" "$NODE_DIR.tmp"
    mkdir -p "$NODE_DIR.tmp"
    run "downloading Node" fetch \
      "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz" "$NODE_DIR.tar.xz"
    check_sha256 "$NODE_DIR.tar.xz" "$NODE_SHA256" || fail "checking Node's checksum"
    run "unpacking Node" tar xJf "$NODE_DIR.tar.xz" --strip-components=1 --directory "$NODE_DIR.tmp"
    rm -f "$NODE_DIR.tar.xz"
    mv "$NODE_DIR.tmp" "$NODE_DIR"
  fi
  if [ "$(readlink "$STATE/node" 2>/dev/null || true)" != "$NODE_DIR" ]; then
    ln -sfn "$NODE_DIR" "$STATE/node"
  fi
}

# Chromium is the one Playwright's own registry names for the Playwright the
# tests run with, so it is installed by that Playwright, kept in its own npm
# prefix here so that this works before (and without) the project's
# node_modules. Only the headless shell, as haskell-halogen's CI installs.
install_chromium() {
  version=$PLAYWRIGHT_VERSION
  if [ -f "$ROOT/package-lock.json" ]; then
    locked=$(jq -r '.packages["node_modules/playwright-core"].version // empty' "$ROOT/package-lock.json")
    version=${locked:-$version}
  fi
  prefix=$STATE/playwright-$version
  cli=$prefix/node_modules/playwright-core/cli.js
  if [ ! -f "$cli" ]; then
    say "installing playwright-core $version into $prefix"
    rm -rf "$prefix"
    run "installing playwright-core" npm install --prefix "$prefix" --no-save --no-audit --no-fund \
      "playwright-core@$version"
  fi
  location=$(node "$cli" install --dry-run --only-shell chromium 2>>"$LOG" |
    sed -n 's/^ *Install location: *//p' | head -n 1)
  [ -n "$location" ] || fail "asking Playwright $version where Chromium goes"
  if [ ! -f "$location/INSTALLATION_COMPLETE" ]; then
    say "installing Chromium (headless shell) for Playwright $version into $location"
    run "installing Chromium" node "$cli" install --only-shell chromium
    run "launching Chromium" node -e '
      const { chromium } = require(process.argv[1]);
      chromium.launch().then((browser) => browser.close());
    ' "$prefix/node_modules/playwright-core"
  fi
  CHROMIUM=$location
}

update_cabal_index() {
  index=$(cd "$STATE" && cabal path --remote-repo-cache 2>>"$LOG")/hackage.haskell.org/01-index.tar
  if [ ! -f "$index" ] || [ -n "${1:-}" ]; then
    say "updating cabal's package index"
    run "updating cabal's package index" sh -c "cd '$STATE' && cabal update"
  fi
}

write_env() {
  env_lines >"$STATE/env.tmp"
  if cmp -s "$STATE/env.tmp" "$STATE/env"; then
    rm -f "$STATE/env.tmp"
  else
    mv "$STATE/env.tmp" "$STATE/env"
  fi
}

toolchain() {
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) ;;
    *)
      say "only x86_64 Linux is supported (the pinned downloads are for it); see README.md"
      exit 1
      ;;
  esac
  started=$(date +%s)
  quiet_before=$(wc -c <"$LOG")
  system_packages
  install_ghcup
  install_native
  install_wasm_sysroot
  install_wasm_ghc
  install_node
  install_chromium
  update_cabal_index
  write_env
  summary="GHC $GHC_VERSION, cabal $CABAL_VERSION, wasm32-wasi-ghc $WASM_GHC_VERSION, Node $NODE_VERSION, Chromium in $CHROMIUM"
  if [ "$(wc -c <"$LOG")" = "$quiet_before" ]; then
    printf 'bootstrap: toolchain already installed (%s)\n' "$summary"
  else
    say "toolchain ready in $(($(date +%s) - started))s: $summary"
  fi
}

# --- Cabal store ------------------------------------------------------------

# What decides a project's dependency plan: its project files, every package
# description in the repository, and the compilers. When none of it changed
# since the last warm-up that succeeded, there is nothing to build.
fingerprint() {
  {
    for f in "$@" cabal.project.freeze cabal.project.local; do
      [ ! -f "$ROOT/$f" ] || cat "$ROOT/$f"
    done
    find "$ROOT" \( -name dist-newstyle -o -name node_modules -o -name .git \) -prune \
      -o -name '*.cabal' -type f -print | LC_ALL=C sort | xargs cat
    ghc --numeric-version
    "$GHCUP_BIN/wasm32-wasi-ghc-$WASM_GHC_VERSION" --numeric-version
  } | sha256sum | cut -d' ' -f1
}

warm_native() {
  (
    unset CC CXX LD AR NM RANLIB STRIP OBJCOPY OBJDUMP SIZE STRINGS
    cd "$ROOT"
    cabal build all --only-dependencies --project-file=cabal.project --builddir=dist-newstyle/native
  )
}

warm_wasm() {
  (
    # shellcheck source=/dev/null
    . "$WASM_PREFIX/env"
    cd "$ROOT"
    # Cabal may reuse the host ghc-pkg from this cache when switching toolchains.
    rm -f dist-newstyle/wasm/cache/compiler
    cabal build all --only-dependencies --project-file=cabal-wasm.project \
      --builddir=dist-newstyle/wasm \
      --with-compiler="$(command -v wasm32-wasi-ghc)" \
      --with-hc-pkg="$(command -v wasm32-wasi-ghc-pkg)" \
      --with-hsc2hs="$(command -v wasm32-wasi-hsc2hs)"
  )
}

warm_one() {
  project=$1 builder=$2
  shift 2
  [ -f "$ROOT/$project" ] || return 0
  found=1
  stamp=$STATE/warm-$(printf '%s' "$ROOT/$project" | sha256sum | cut -c1-16)
  sum=$(fingerprint "$@")
  if [ "$(cat "$stamp" 2>/dev/null || true)" = "$sum" ]; then
    printf 'bootstrap: %s dependencies already built\n' "$project"
    return 0
  fi
  if [ -z "$updated" ]; then
    update_cabal_index force
    updated=1
  fi
  say "building $project's dependencies into the cabal store (this can take a while)"
  started=$(date +%s)
  run "building $project's dependencies" "$builder"
  printf '%s\n' "$sum" >"$stamp"
  say "built $project's dependencies in $(($(date +%s) - started))s"
}

warm() {
  found= updated=
  warm_one cabal.project warm_native cabal.project
  warm_one cabal-wasm.project warm_wasm cabal.project cabal-wasm.project
  [ -n "$found" ] || printf 'bootstrap: no cabal.project yet, nothing to warm\n'
}

# --- Main -------------------------------------------------------------------

printf '\n=== %s bootstrap %s (%s)\n' "$(date '+%F %T')" "$mode" "$ROOT" >>"$LOG"

# The toolchain and the store have a lock each, so a run that is only warming
# the store does not hold up one that only wants the toolchain.
(
  lock toolchain
  toolchain
) 9>"$STATE/toolchain.lock"

if [ "$mode" = all ] || [ "$mode" = warm ]; then
  (
    lock "the cabal store"
    warm
  ) 9>"$STATE/warm.lock"
fi
