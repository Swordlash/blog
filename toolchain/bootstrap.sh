#!/bin/sh
# Install the toolchain this repository builds with, and warm the cabal store.
#
#   sh toolchain/bootstrap.sh             # toolchain, then warm the store
#   sh toolchain/bootstrap.sh toolchain   # the toolchain only
#   sh toolchain/bootstrap.sh warm        # the toolchain if missing, then warm
#   sh toolchain/bootstrap.sh env         # print the PATH lines a shell needs
#   sh toolchain/bootstrap.sh path        # the same directories, one per line
#   sh toolchain/bootstrap.sh check       # read-only inventory; never installs
#   sh toolchain/bootstrap.sh ready [build-native|test-native|build-wasm|test-wasm|test|dev-test|serve-wasm]
#                                        # strict, read-only npm readiness gate
#
# It reuses compatible tools on PATH first. Missing tools are installed on
# x86_64 Linux as follows:
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
#   - fourmolu $FOURMOLU_VERSION, which `npm run format` runs, into ghcup's bin
#     directory: its release binary, or where that download is refused, built
#     from Hackage with cabal (about a quarter of an hour, once);
#   - alex $ALEX_VERSION and happy $HAPPY_VERSION, native, into ghcup's bin
#     directory, built from Hackage with the host GHC (a couple of minutes,
#     once): the wasm build of ghc-lib-parser (under haskell-halogen-th) runs
#     them from PATH;
#   - the Debian packages these need, Chromium's included, if they are missing
#     and it can (root or password-less sudo); otherwise it names them and stops.
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
# A developer runs it by hand the same way. When PATH lacks a pinned compiler,
# it installs or activates it through ghcup, and leaves the shell's PATH alone:
# afterwards, put
#
#   . ~/.wiki-toolchain/env
#
# in your shell profile (or run it in the shell you build from), and source
# ~/.ghc-wasm/env where a script needs the wasm tools, as the build scripts do.
#
# CI on a self-hosted runner runs it the same way (`toolchain`), and appends
# what `path` prints to $GITHUB_PATH: one directory per line, in the order
# GitHub wants them there, where the last line is searched first.
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
# The formatter, at the version the README names and CI checks with
# (.github/workflows/build.yml holds the same version and checksum). The
# checksum is that of the release's linux-x86_64 binary, checked when it is
# set. It is not set yet: the release could not be downloaded where this was
# written, and CI prints it (the format job's "Install fourmolu" step), so
# copy it from there into both places.
FOURMOLU_VERSION=0.21.0.0
FOURMOLU_SHA256=
# The lexer and parser generators ghc-lib-parser runs while it compiles. For a
# cross build cabal makes them for wasm too (alex.wasm, happy.wasm), cannot run
# those, and falls back to the alex and happy on PATH, which must be native
# programs and a happy ghc-lib-parser accepts: it refuses 2.2. haskell-halogen's
# CI installs them the same way (with `--constraint='happy <2.2'`); here they
# are pinned so that every machine runs the same ones.
ALEX_VERSION=3.5.4.2
HAPPY_VERSION=2.1.7

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE=$HOME/.wiki-toolchain
LOG=$STATE/bootstrap.log
WASM_PREFIX=$HOME/.ghc-wasm
META_DIR=$STATE/ghc-wasm-meta-$GHC_WASM_META_REV
NODE_DIR=$STATE/node-v$NODE_VERSION-linux-x64

mode=${1:-all}
case $mode in
  all | toolchain | warm | env | path | check | ready) ;;
  *)
    printf 'usage: %s [all|toolchain|warm|env|path|check|ready [build-native|test-native|build-wasm|test-wasm|test|dev-test|serve-wasm]]\n' "$0" >&2
    exit 2
    ;;
esac

# Where ghcup puts its symlinks: the bin directory of a ghcup already on PATH,
# or the default one this script installs into.
if [ "$mode" != ready ] && command -v ghcup >/dev/null 2>&1; then
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
PATH=\$(
  remaining=\$PATH
  printf '%s' "$STATE/node/bin:$GHCUP_BIN"
  while :; do
    case \$remaining in
      *:*) entry=\${remaining%%:*}; remaining=\${remaining#*:}; last= ;;
      *) entry=\$remaining; last=1 ;;
    esac
    case \$entry in
      "$STATE/node/bin" | "$GHCUP_BIN") ;;
      *) printf ':%s' "\$entry" ;;
    esac
    [ -z "\$last" ] || break
  done
)
export PATH
EOF
}

# The same two directories for $GITHUB_PATH, which prepends each line in turn:
# ghcup's first, so that Node's, written last, ends up first, as in env_lines.
path_lines() {
  printf '%s\n' "$GHCUP_BIN" "$STATE/node/bin"
}

case $mode in
  env)
    env_lines
    exit 0
    ;;
  path)
    path_lines
    exit 0
    ;;
esac

# Inventory and installation discover managed tools too. Readiness must see
# the caller's actual PATH: finding an unloaded installation would hide why
# the command this gate protects cannot run it.
if [ "$mode" != ready ]; then
  PATH=$STATE/node/bin:$GHCUP_BIN:$PATH
  export PATH
fi

numeric_version() {
  "$1" --numeric-version 2>/dev/null || true
}

# Use --version for alex and happy: their older releases do not implement
# --numeric-version. Match a whole version, not a prefix such as 2.1.70.
generator_version() {
  "$1" --version 2>/dev/null | sed -n '1s/^[^0-9]*\([0-9][0-9.]*\).*$/\1/p'
}

compatible_node() {
  node_major=$(node --version 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\)\..*/\1/p')
  [ -n "$node_major" ] && [ "$node_major" -ge 24 ] && command -v npm >/dev/null 2>&1
}

# A provenance marker alone does not prove setup finished. Check the actual
# tools and libc, without sourcing an unrecognised env file.
wasm_sysroot_ready() {
  { [ -f "$WASM_PREFIX/.bootstrap-$GHC_WASM_META_REV" ] ||
    [ "$(cat "$WASM_PREFIX/.paladyn-rev" 2>/dev/null || true)" = "$GHC_WASM_META_REV" ]; } &&
    [ -r "$WASM_PREFIX/env" ] &&
    [ -x "$WASM_PREFIX/add_to_github_path.sh" ] &&
    [ -f "$WASM_PREFIX/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/libc.a" ] &&
    "$WASM_PREFIX/wasi-sdk/bin/wasm32-wasi-clang" --version >/dev/null 2>&1 &&
    "$WASM_PREFIX/binaryen/bin/wasm-opt" --version >/dev/null 2>&1 &&
    "$WASM_PREFIX/wasmtime/bin/wasmtime" --version >/dev/null 2>&1 &&
    "$WASM_PREFIX/nodejs/bin/node" --version >/dev/null 2>&1
}

guard_wasm_sysroot() {
  wasm_sysroot_ready && return 0
  if [ -e "$WASM_PREFIX" ] || [ -L "$WASM_PREFIX" ]; then
    if [ ! -d "$WASM_PREFIX" ] || [ -L "$WASM_PREFIX" ] ||
      [ -n "$(find "$WASM_PREFIX" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
      printf 'bootstrap: BLOCKED: %s is unrecognised or incomplete; refusing to overwrite it. Inspect it and move it aside yourself before retrying.\n' "$WASM_PREFIX" >&2
      return 1
    fi
  fi
}

playwright_location() {
  version=$PLAYWRIGHT_VERSION
  if [ -f "$ROOT/package-lock.json" ] && command -v node >/dev/null 2>&1; then
    locked=$(node -e 'const p=require(process.argv[1]); process.stdout.write(p.packages?.["node_modules/playwright-core"]?.version || "")' "$ROOT/package-lock.json")
    version=${locked:-$version}
  fi
  prefix=$STATE/playwright-$version
  for candidate in "$ROOT" "$prefix"; do
    if [ -f "$candidate/node_modules/playwright-core/cli.js" ] &&
      [ "$(node -p 'require(process.argv[1]).version' "$candidate/node_modules/playwright-core/package.json" 2>/dev/null || true)" = "$version" ]; then
      prefix=$candidate
      cli=$prefix/node_modules/playwright-core/cli.js
      return 0
    fi
  done
  # A stale private installation is replaced; a project's other version is
  # left alone, since the lockfile decides which Chromium the tests need.
  prefix=$STATE/playwright-$version
  cli=
}

check_tool() {
  name=$1 expected=$2 managed_tool=$3 managed_version=$4
  if [ "$(numeric_version "$name")" = "$expected" ]; then
    printf 'bootstrap: reuse %s %s (%s)\n' "$name" "$expected" "$(command -v "$name")"
  elif managed_tool_ready "$managed_tool" "$managed_version" "$name-$expected" "$expected"; then
    printf 'bootstrap: reuse %s (%s); activate pinned default\n' "$name-$expected" "$GHCUP_BIN/$name-$expected"
  else
    printf 'bootstrap: install %s %s\n' "$name" "$expected"
  fi
}

managed_tool_ready() {
  [ "$("$GHCUP_BIN/$3" --numeric-version 2>/dev/null || true)" = "$4" ] &&
    "$GHCUP" whereis "$1" "$2" >/dev/null 2>&1
}

chromium_cached() {
  # Playwright changed the archive's executable name from headless_shell to
  # chrome-headless-shell. Its registry knows both the platform and revision;
  # ask it rather than duplicating the archive layout here.
  node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const root = process.argv[1];
    const bundled = path.join(root, "lib/coreBundle.js");
    const { registry } = fs.existsSync(bundled)
      ? require(bundled).registry
      : require(path.join(root, "lib/server/registry/index.js"));
    const browser = registry.findExecutable("chromium-headless-shell");
    fs.accessSync(path.join(browser.directory, "INSTALLATION_COMPLETE"), fs.constants.R_OK);
    fs.accessSync(browser.executablePath(), fs.constants.X_OK);
  ' "$prefix/node_modules/playwright-core" >/dev/null 2>&1
}

check() {
  blocked=0
  check_tool ghc "$GHC_VERSION" ghc "$GHC_VERSION"
  check_tool cabal "$CABAL_VERSION" cabal "$CABAL_VERSION"
  check_tool wasm32-wasi-ghc "$WASM_GHC_VERSION" ghc "wasm32-wasi-$WASM_GHC_VERSION"
  if wasm_sysroot_ready; then
    printf 'bootstrap: reuse wasm sysroot %s\n' "$WASM_PREFIX"
  elif guard_wasm_sysroot; then
    printf 'bootstrap: install wasm sysroot %s\n' "$WASM_PREFIX"
  else
    blocked=1
  fi
  if compatible_node; then
    printf 'bootstrap: reuse Node %s (%s), npm (%s)\n' "$(node --version)" "$(command -v node)" "$(command -v npm)"
  else
    printf 'bootstrap: install Node %s (requires Node >=24 and npm)\n' "$NODE_VERSION"
  fi
  for spec in "alex:$ALEX_VERSION" "happy:$HAPPY_VERSION"; do
    name=${spec%%:*} expected=${spec#*:}
    if [ "$(generator_version "$name")" = "$expected" ]; then
      printf 'bootstrap: reuse %s %s (%s)\n' "$name" "$expected" "$(command -v "$name")"
    else
      printf 'bootstrap: install %s %s (found: %s)\n' "$name" "$expected" "$(generator_version "$name")"
    fi
  done
  if [ "$(fourmolu --version 2>/dev/null | head -n 1 || true)" = "fourmolu $FOURMOLU_VERSION" ]; then
    printf 'bootstrap: reuse fourmolu %s (%s)\n' "$FOURMOLU_VERSION" "$(command -v fourmolu)"
  else
    printf 'bootstrap: install fourmolu %s\n' "$FOURMOLU_VERSION"
  fi
  playwright_location
  if [ -n "$cli" ]; then
    printf 'bootstrap: reuse playwright-core %s (%s)\n' "$version" "$prefix"
    location=$(node "$cli" install --dry-run --only-shell chromium 2>/dev/null | sed -n 's/^ *Install location: *//p' | head -n 1)
    if [ -n "$location" ] && chromium_cached; then
      printf 'bootstrap: reuse Chromium cache %s (launch checked during install mode)\n' "$location"
    else
      printf 'bootstrap: install Chromium headless shell for Playwright %s\n' "$version"
    fi
  else
    printf 'bootstrap: install playwright-core %s and its Chromium headless shell\n' "$version"
  fi
  printf 'bootstrap: install modes also check system packages and the cabal index; all/warm build dependencies.\n'
  return "$blocked"
}

require_version() {
  if [ "$(numeric_version "$1")" != "$2" ]; then
    printf 'bootstrap: not ready: %s%s %s is required on PATH (found: %s; path: %s).\n' \
      "${ready_context:-}" "$1" "$2" "$(numeric_version "$1")" "$(command -v "$1" || true)" >&2
    ready_failed=1
  fi
}

require_generators() {
  for spec in "alex:$ALEX_VERSION" "happy:$HAPPY_VERSION"; do
    name=${spec%%:*} expected=${spec#*:}
    if [ "$(generator_version "$name")" != "$expected" ]; then
      printf 'bootstrap: not ready: %s%s %s is required on PATH (found: %s; path: %s).\n' \
        "${ready_context:-}" "$name" "$expected" "$(generator_version "$name")" "$(command -v "$name" || true)" >&2
      ready_failed=1
    fi
  done
}

# Do not launch Chromium here: its cache can be checked without creating a
# browser profile or lock files. Install mode verifies runtime libraries by
# launching it. Wasm's env is loaded only in a subshell, as the build does,
# so native tools are checked before its CC and PATH can take over.
ready() {
  target=${2:-build-wasm}
  case $target in
    build-native | test-native | build-wasm | test-wasm | test | dev-test | serve-wasm) ;;
    *) printf 'bootstrap: unknown readiness target: %s\n' "$target" >&2; return 2 ;;
  esac
  ready_failed=0
  ready_context=
  require_version ghc "$GHC_VERSION"
  require_version cabal "$CABAL_VERSION"
  require_generators
  if [ "$(fourmolu --version 2>/dev/null | head -n 1 || true)" != "fourmolu $FOURMOLU_VERSION" ]; then
    printf 'bootstrap: not ready: fourmolu %s is required on PATH (found: %s; path: %s).\n' \
      "$FOURMOLU_VERSION" "$(fourmolu --version 2>/dev/null | head -n 1 || true)" "$(command -v fourmolu || true)" >&2
    ready_failed=1
  fi
  if ! wasm_sysroot_ready; then
    printf 'bootstrap: not ready: the pinned wasm sysroot in %s is missing or incomplete.\n' "$WASM_PREFIX" >&2
    ready_failed=1
  elif ! (
    . "$WASM_PREFIX/env" || exit 1
    ready_failed=0
    ready_context='wasm environment: '
    require_version wasm32-wasi-ghc "$WASM_GHC_VERSION"
    require_version ghc "$GHC_VERSION"
    require_version cabal "$CABAL_VERSION"
    require_generators
    if ! compatible_node; then
      printf 'bootstrap: not ready: the wasm environment must provide Node >=24 and npm.\n' >&2
      ready_failed=1
    fi
    for name in wasm32-wasi-ghc-pkg wasm32-wasi-hsc2hs wasm-opt; do
      if ! command -v "$name" >/dev/null 2>&1; then
        printf 'bootstrap: not ready: %s is missing after loading the wasm environment.\n' "$name" >&2
        ready_failed=1
      fi
    done
    [ "$ready_failed" = 0 ]
  ); then
    printf 'bootstrap: not ready: loading or checking the wasm environment failed.\n' >&2
    ready_failed=1
  fi
  if ! compatible_node; then
    printf 'bootstrap: not ready: Node >=24 and npm are required on PATH.\n' >&2
    ready_failed=1
  else
    playwright_location
    location=
    if [ -n "$cli" ]; then
      location=$(node "$cli" install --dry-run --only-shell chromium 2>/dev/null | sed -n 's/^ *Install location: *//p' | head -n 1)
    fi
    if [ -z "$location" ] || ! chromium_cached; then
      printf 'bootstrap: not ready: Chromium headless shell for Playwright %s is missing.\n' "$version" >&2
      ready_failed=1
    fi
    if ! node "$ROOT/toolchain/check-npm-deps.cjs" "$ROOT" "$target"; then
      ready_failed=1
    fi
  fi
  if [ "$ready_failed" != 0 ]; then
    printf 'bootstrap: run `sh toolchain/bootstrap.sh toolchain`, then retry. npm build, serve and test commands load ~/.wiki-toolchain/env automatically; for direct commands, load `. ~/.wiki-toolchain/env` in this shell.\n' >&2
    return 1
  fi
  printf 'bootstrap: ready for %s.\n' "$target"
}

if [ "$mode" = ready ]; then
  ready "$@"
  exit $?
fi

if [ "$mode" = check ]; then
  check
  exit $?
fi

# setup.sh deletes its prefix: refuse unsafe state before changing anything.
guard_wasm_sysroot || exit 1
mkdir -p "$STATE"

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

# Set $sudo to what runs a command as root (nothing when this already is root),
# or fail when that would need a password: this script never asks for one.
as_root() {
  if [ "$(id -u)" = 0 ]; then
    sudo=
  elif sudo -n true 2>/dev/null; then
    sudo=sudo
  else
    return 1
  fi
}

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
  if ! as_root; then
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
  if ! managed_tool_ready "$tool" "$version" "$binary" "$reports"; then
    say "installing $tool $version with ghcup"
    if "$GHCUP" whereis "$tool" "$version" >/dev/null 2>&1; then
      run "removing a broken $tool $version" "$GHCUP" rm "$tool" "$version"
    fi
    run "installing $tool $version" "$@"
  fi
}

install_native() {
  if [ "$(ghc --numeric-version 2>/dev/null || true)" != "$GHC_VERSION" ]; then
    install_ghcup
    ghcup_tool ghc "$GHC_VERSION" "ghc-$GHC_VERSION" "$GHC_VERSION" \
      "$GHCUP" install ghc "$GHC_VERSION"
    run "making GHC $GHC_VERSION the default" "$GHCUP" set ghc "$GHC_VERSION"
  fi
  if [ "$(cabal --numeric-version 2>/dev/null || true)" != "$CABAL_VERSION" ]; then
    install_ghcup
    ghcup_tool cabal "$CABAL_VERSION" "cabal-$CABAL_VERSION" "$CABAL_VERSION" \
      "$GHCUP" install cabal "$CABAL_VERSION"
    run "making cabal $CABAL_VERSION the default" "$GHCUP" set cabal "$CABAL_VERSION"
  fi
}

# ghc-wasm-meta's setup.sh starts by deleting ~/.ghc-wasm, so the stamp it is
# given at the end only exists after a complete run, and only for this revision.
fetch_wasm_meta() {
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
}

install_wasm_sysroot() {
  if ! wasm_sysroot_ready; then
    guard_wasm_sysroot || exit 1
    fetch_wasm_meta
    say "installing the wasm sysroot into $WASM_PREFIX (wasi-sdk, binaryen, wasmtime, Node)"
    run "installing the wasm sysroot" env PREFIX="$WASM_PREFIX" SKIP_GHC=1 FLAVOUR="$GHC_WASM_FLAVOUR" bash "$META_DIR/setup.sh"
    touch "$WASM_PREFIX/.bootstrap-$GHC_WASM_META_REV"
    wasm_sysroot_ready || fail "verifying the wasm sysroot (inspect it before retrying)"
  fi
}

# The cross compiler, installed from ghc-wasm-meta's ghcup metadata with the
# configure arguments its env file exports, as haskell-halogen's CI does.
install_wasm_ghc() {
  [ "$(wasm32-wasi-ghc --numeric-version 2>/dev/null || true)" != "$WASM_GHC_VERSION" ] || return 0
  install_ghcup
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
  fetch_wasm_meta
  (
    # shellcheck source=/dev/null
    . "$WASM_PREFIX/env"
    # shellcheck disable=SC2086
    "$GHCUP" -s "file://$META_DIR/ghcup-wasm-0.0.9.yaml" \
      install ghc "wasm32-wasi-$WASM_GHC_VERSION" --set -- $CONFIGURE_ARGS
  )
}

install_node() {
  compatible_node && return 0
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
#
# The shared libraries it needs are Debian packages that differ between
# releases (Ubuntu 24.04 renamed several), so they are not in system_packages:
# Playwright knows the list for each release. When Chromium does not start,
# Playwright installs them if this can run it as root, and otherwise this names
# them and stops. Until Chromium has once started, every run tries again, so a
# run after the packages were installed by hand finishes the job.
install_chromium() {
  playwright_location
  if [ -z "$cli" ]; then
    say "installing playwright-core $version into $prefix"
    rm -rf "$prefix"
    run "installing playwright-core" npm install --prefix "$prefix" --no-save --no-audit --no-fund \
      "playwright-core@$version"
    cli=$prefix/node_modules/playwright-core/cli.js
  fi
  location=$(node "$cli" install --dry-run --only-shell chromium 2>>"$LOG" |
    sed -n 's/^ *Install location: *//p' | head -n 1)
  [ -n "$location" ] || fail "asking Playwright $version where Chromium goes"
  if ! chromium_cached; then
    say "installing Chromium (headless shell) for Playwright $version into $location"
    run "installing Chromium" node "$cli" install --only-shell chromium
  fi
  # A previous launch stamp cannot prove today's shared libraries or browser
  # binary still work. Launch the cached browser on each install-mode run.
  if ! launch_chromium "$prefix"; then
    if ! as_root; then
      say "Chromium does not start (the end of $LOG says why); the Debian packages Playwright would install or upgrade for it:"
      node "$cli" install-deps --dry-run chromium 2>&1 | sed 's/^/bootstrap:   /'
      say "install them (sudo apt-get install ...) and run this again"
      exit 1
    fi
    say "installing the Debian packages Chromium needs"
    # $sudo is empty when this already runs as root.
    # shellcheck disable=SC2086
    run "installing Chromium's Debian packages" $sudo "$(command -v node)" "$cli" install-deps chromium
    launch_chromium "$prefix" || fail "launching Chromium"
  fi
  CHROMIUM=$location
}

launch_chromium() {
  printf '+ launch Chromium\n' >>"$LOG"
  node -e '
    const { chromium } = require(process.argv[1]);
    chromium.launch().then((browser) => browser.close());
  ' "$1/node_modules/playwright-core" >>"$LOG" 2>&1
}

# Any fourmolu on PATH that reports the pinned version will do, wherever it
# came from. Otherwise the release binary goes into ghcup's bin directory, which
# the env file already puts on PATH; a network that refuses GitHub's release
# downloads (Claude Code's cloud sessions do) gets one built from Hackage
# instead, which is slow but needs nothing else. The log says which it was.
install_fourmolu() {
  if [ "$(fourmolu --version 2>/dev/null | head -n 1 || true)" = "fourmolu $FOURMOLU_VERSION" ]; then
    FOURMOLU=$(command -v fourmolu)
    return 0
  fi
  FOURMOLU=$GHCUP_BIN/fourmolu
  mkdir -p "$GHCUP_BIN"
  tmp=$FOURMOLU.download
  rm -f "$tmp"
  printf '+ fetch fourmolu %s release binary\n' "$FOURMOLU_VERSION" >>"$LOG"
  if fetch "https://github.com/fourmolu/fourmolu/releases/download/v$FOURMOLU_VERSION/fourmolu-$FOURMOLU_VERSION-linux-x86_64" \
    "$tmp" >>"$LOG" 2>&1; then
    if [ -n "$FOURMOLU_SHA256" ]; then
      check_sha256 "$tmp" "$FOURMOLU_SHA256" || fail "checking fourmolu's checksum"
    fi
    chmod 755 "$tmp"
    mv "$tmp" "$FOURMOLU"
    say "installed fourmolu $FOURMOLU_VERSION's release binary into $GHCUP_BIN"
  else
    rm -f "$tmp"
    say "fourmolu's release binary could not be downloaded; building fourmolu $FOURMOLU_VERSION from Hackage into $GHCUP_BIN (this takes a while)"
    run "building fourmolu" cabal install "fourmolu-$FOURMOLU_VERSION" --ignore-project \
      --with-compiler="$(command -v ghc)" --installdir="$GHCUP_BIN" \
      --install-method=copy --overwrite-policy=always
    say "built fourmolu $FOURMOLU_VERSION from Hackage into $GHCUP_BIN"
  fi
}

# Native alex and happy at the pins, into ghcup's bin directory, which the env
# file and `path` put on PATH ahead of anything else; skipped when the ones
# found there already report the pinned versions.
install_parser_generators() {
  for spec in "alex:$ALEX_VERSION" "happy:$HAPPY_VERSION"; do
    generator=${spec%%:*} wanted=${spec#*:}
    [ "$(generator_version "$generator")" != "$wanted" ] || continue
    mkdir -p "$GHCUP_BIN"
    say "building $generator $wanted from Hackage into $GHCUP_BIN"
    run "building $generator" cabal install "$generator-$wanted" \
      --ignore-project --with-compiler="$(command -v ghc)" --installdir="$GHCUP_BIN" \
      --install-method=copy --overwrite-policy=always
  done
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
  install_native
  install_wasm_sysroot
  install_wasm_ghc
  install_node
  install_chromium
  update_cabal_index
  install_fourmolu
  install_parser_generators
  write_env
  summary="GHC $GHC_VERSION, cabal $CABAL_VERSION, wasm32-wasi-ghc $WASM_GHC_VERSION, Node $(node --version), Chromium in $CHROMIUM, fourmolu $FOURMOLU_VERSION at $FOURMOLU, alex $ALEX_VERSION, happy $HAPPY_VERSION"
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
    wasm32-wasi-ghc --numeric-version
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
  found='' updated=''
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
