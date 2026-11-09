#!/bin/sh
# Install the toolchain this repository builds with, and warm the cabal store.
#
#   sh toolchain/bootstrap.sh             # toolchain, then warm the store
#   sh toolchain/bootstrap.sh toolchain   # the toolchain only
#   sh toolchain/bootstrap.sh build       # what a build needs: no Chromium, no fourmolu
#   sh toolchain/bootstrap.sh native      # the host GHC and cabal alone, for wiki-server
#   sh toolchain/bootstrap.sh node        # Node alone, to serve the demo's page CI built
#   sh toolchain/bootstrap.sh static      # GHC, cabal and Node: the deploy of the demo's page CI built
#   sh toolchain/bootstrap.sh maker       # GHC and cabal, and the maker built with them: what
#                                        # toolchain/deploy-local.sh needs before the maker runs it
#   sh toolchain/bootstrap.sh system-tools [native] [node]
#                                        # read-only: whether this machine's own GHC and
#                                        # cabal (native) and Node (node) will do
#   sh toolchain/bootstrap.sh warm        # the toolchain if missing, then warm
#   sh toolchain/bootstrap.sh env         # print the PATH lines a shell needs
#   sh toolchain/bootstrap.sh path        # the same directories, one per line
#   sh toolchain/bootstrap.sh check       # read-only inventory; never installs
#   sh toolchain/bootstrap.sh ready [build-native|test-native|build-wasm|build-wasm-opt|test-wasm|test|dev-test|serve-wasm]
#                                        # read-only readiness gate for that npm command:
#                                        # it checks what the command needs, no more
#
# It works in two stages. This script is the first: in POSIX sh, it does
# what must work before there is a GHC (the read-only modes, the check of
# the machine's own tools, the system packages GHC itself needs, ghcup with
# GHC and cabal, the Hackage mirror and cabal's index) and the deploy's node
# mode in full, since that mode installs no GHC. Every other installing mode,
# native included, then hands over to the second stage, the maker (maker/, a
# Haskell program on Shake built with its own cabal project, once, from
# Hackage or the mirror), which installs the rest below (the system packages
# of the builds' C libraries first) and warms the store. The maker's own
# command line and terminal interface are toolchain/maker.sh.
#
# It reuses compatible tools on PATH first. Missing tools are installed on
# x86_64 Linux as follows:
#
#   - ghcup (into ~/.ghcup, unless one is already on PATH), and through it
#     GHC $GHC_VERSION and cabal $CABAL_VERSION, both made the default;
#     (~ here is the home directory, or the directory WIKI_TOOLCHAIN_HOME
#     names: toolchain/deploy-local.sh --prefix installs the toolchain under
#     <prefix>/toolchain, and then ghcup, cabal, npm and Playwright keep their
#     files there as well, through their own variables, which the env file
#     exports; without it their defaults stand, as do ghcup's and cabal's
#     own directories);
#   - ghc-wasm-meta at $GHC_WASM_META_REV (into ~/.ghc-wasm: wasi-sdk,
#     binaryen, wasmtime and its own Node), and through ghcup the cross compiler
#     wasm32-wasi-ghc-$WASM_GHC_VERSION, exactly as haskell-halogen's CI does;
#     the revision comes from gitlab.haskell.org, or from its GitHub mirror
#     where that host is refused;
#   - Node $NODE_VERSION, into ~/.wiki-toolchain/node;
#   - libsodium $LIBSODIUM_VERSION, which every native build links statically,
#     built from source by toolchain/libsodium.sh into
#     ~/.wiki-toolchain/libsodium-$LIBSODIUM_VERSION (behind the link
#     ~/.wiki-toolchain/libsodium), in every mode that builds natively, with
#     --system-tools too: Debian and Ubuntu ship a libsodium too old for the
#     opaque package, and a static library leaves wiki-server needing none
#     on the machine it runs on. Its release tarball comes from
#     download.libsodium.org or GitHub, or with --libsodium-source=FILE
#     (native and build) from a file brought onto the machine by hand,
#     checked against the same checksum;
#   - Chromium's headless shell for Playwright, the revision the project's
#     Playwright (package-lock.json, or $PLAYWRIGHT_VERSION before there is
#     one) asks for, into $PLAYWRIGHT_BROWSERS_PATH or Playwright's default;
#   - fourmolu $FOURMOLU_VERSION, which `npm run format` runs, into ghcup's bin
#     directory: its release binary, or where that download is refused, built
#     from Hackage with cabal (about a quarter of an hour, once);
#   - the Debian packages these need, Chromium's included, if they are missing
#     and it can (root or password-less sudo); otherwise it names them and stops.
#     This script installs those GHC needs (a C toolchain, GMP's development
#     files, curl and xz); the maker those of the builds (git, pkg-config,
#     zlib, libpq, ncurses for the wizard, and jq, unzip and zstd for the
#     wasm sysroot's setup).
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
# of the log. In the modes toolchain/deploy-local.sh uses (native and build),
# the long steps' output (ghcup's installs, cabal's builds and index update,
# the wasm sysroot's setup) is shown on the terminal as well.
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
# `build` installs what building the wiki needs and nothing that only tests or
# formatting do: everything above but Chromium (with the Debian packages it
# needs) and fourmolu. The Dockerfile's builder stage runs it, so that the
# image is built with the pins below and the downloads they check, and does not
# carry a browser it never starts.
#
# `native` installs what building wiki-server natively needs and nothing
# else: GHC and cabal through ghcup, the system packages a native build
# links with, libsodium built from source, and cabal's package index; no
# wasm sysroot, cross compiler, Node, Chromium or fourmolu, none of which a
# native build of wiki-server needs. toolchain/deploy-local.sh --backend-only runs it, on a
# machine that downloads the page instead of building it. It does not assume
# Debian: without dpkg-query it installs no system packages, and only checks
# the commands GHC needs. Either way the maker then installs the C
# libraries' packages and checks the commands and C libraries wiki-server's
# build needs (`maker check native`, the same check as
# toolchain/check-native.sh), naming the Debian and RHEL packages of any that
# are missing. `native --without-postgres` is for a
# wiki-server built without PostgreSQL (the cabal flag postgres off), which
# needs no libpq: it does not ask Debian for libpq-dev, and passes the
# option to the check. `build --without-postgres` leaves libpq-dev out the
# same way. toolchain/deploy-local.sh gives the option to both modes for a
# wiki in SQLite. `native --with-wizard` is for the configuration wizard
# (toolchain/configure.sh, which runs it): it also asks Debian for
# libncurses-dev, whose libtinfo the wizard's terminal library links, and
# passes the option to the check, which then checks terminfo.
#
# `node` installs Node alone: Node $NODE_VERSION into ~/.wiki-toolchain/node,
# unless a Node 24 or later with npm is on PATH already, and the env file.
# It installs no compilers, wasm sysroot, Chromium or fourmolu, and no
# system packages, and leaves ~/.ghc-wasm alone. Before a download it
# checks for curl, tar and xz, which fetch and unpack Node.
#
# `static` installs what the deploy of a demo whose page is not built on the
# machine needs (toolchain/deploy-local.sh --static --backend-only, or
# --app-page): Node, which serves the page (server.mjs) and writes its
# brotli copies (compress.mjs), and GHC and cabal, which build the maker
# that does the rest of the deploy. It installs the system packages GHC
# needs and none of the C libraries', no wasm sysroot, Chromium or
# fourmolu, and leaves ~/.ghc-wasm alone. It takes --system-tools (GHC,
# cabal and Node, the machine's own) and --hackage-mirror=URL.
#
# `native --system-tools`, `static --system-tools` and `node --system-tools`
# install no GHC, cabal, ghcup or Node: they take the machine's own from PATH, for a machine whose
# software must come from its administrators' sources
# (toolchain/deploy-local.sh --system-tools passes it). Before anything
# else they check them: GHC $GHC_MIN_VERSION or later and cabal
# $CABAL_MIN_VERSION or later (native), Node $NODE_MIN_MAJOR or later with npm (node). A
# tool that is missing or older stops the run, named with the version
# found; one that is not the pinned version is used with a warning, since
# only the pins are tested. The rest is as without it: the Debian packages
# a build links with still come through apt, from the machine's own package
# sources, the cabal index is updated, and libsodium is built from its
# release tarball, which is downloaded unless --libsodium-source=FILE gives
# it (below). `system-tools native node` is the
# same check alone, and changes nothing. `build` takes no --system-tools:
# the page's build needs the wasm toolchain, which no machine has of its
# own. The environment file then puts nothing first on PATH.
#
# `native --hackage-mirror=URL` and `build --hackage-mirror=URL` write URL,
# a mirror of Hackage, into the toolchain's own cabal configuration
# ($CABAL_DIR/config, which exists only under a WIKI_TOOLCHAIN_HOME other
# than the home directory; elsewhere the option is refused, since cabal's
# configuration there is the user's) before the index is updated, so that
# cabal takes the index and every package from it. See hackage_config. A
# later run without the option puts Hackage's own address back.
#
# `native --libsodium-source=FILE` and `build --libsodium-source=FILE` take
# libsodium's release tarball (libsodium-$LIBSODIUM_VERSION.tar.gz) from
# FILE instead of downloading it, for a machine that downloads nothing:
# toolchain/libsodium.sh copies it and checks it against LIBSODIUM_SHA256
# exactly as it checks a download, and a file with another checksum stops
# the run with nothing built. FILE must be there when the run starts. It is
# used only when libsodium is not installed yet; an installed one is
# reused, and the maker says the file was not used.
#
# CI on a self-hosted runner runs it the same way (`toolchain`), and appends
# what `path` prints to $GITHUB_PATH: one directory per line, in the order
# GitHub wants them there, where the last line is searched first.
set -eu

# The pins and floors (GHC_VERSION, NODE_VERSION, GHC_MIN_VERSION, …), in
# toolchain/pins.env, the one place that says them: the maker (maker/) and
# toolchain/deploy-local.sh read the same file.
# shellcheck source=toolchain/pins.env
. "$(cd "$(dirname "$0")" && pwd)/pins.env"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Where the toolchain goes: under the home directory, or under the directory
# WIKI_TOOLCHAIN_HOME names, with the same layout below it. A named directory
# (not the home directory itself) also tells ghcup, cabal, npm and Playwright
# to keep their files there, so that a deployment under a prefix leaves
# nothing in the home directory; the home directory leaves their defaults
# alone, as before.
BASE=${WIKI_TOOLCHAIN_HOME:-$HOME}
NAMED_BASE=
if [ -n "${WIKI_TOOLCHAIN_HOME:-}" ] && [ "$(realpath -m "$WIKI_TOOLCHAIN_HOME")" != "$(realpath -m "$HOME")" ]; then
  NAMED_BASE=1
  GHCUP_INSTALL_BASE_PREFIX=$BASE
  CABAL_DIR=$BASE/.cabal
  npm_config_cache=$BASE/.npm
  PLAYWRIGHT_BROWSERS_PATH=$BASE/.cache/ms-playwright
  export GHCUP_INSTALL_BASE_PREFIX CABAL_DIR npm_config_cache PLAYWRIGHT_BROWSERS_PATH
fi
STATE=$BASE/.wiki-toolchain
LOG=$STATE/bootstrap.log
WASM_PREFIX=$BASE/.ghc-wasm
NODE_DIR=$STATE/node-v$NODE_VERSION-linux-x64

mode=${1:-all}
case $mode in
  all | toolchain | build | native | static | maker | node | warm | env | path | check | ready | system-tools) ;;
  *)
    printf 'usage: %s [all|toolchain|build [--without-postgres] [--hackage-mirror=URL] [--libsodium-source=FILE]|native [--without-postgres] [--with-wizard] [--system-tools] [--hackage-mirror=URL] [--libsodium-source=FILE]|static [--system-tools] [--hackage-mirror=URL]|maker [--system-tools] [--hackage-mirror=URL]|node [--system-tools]|warm|env [--system-tools]|path|check|ready [build-native|test-native|build-wasm|build-wasm-opt|test-wasm|test|dev-test|serve-wasm]|system-tools [native] [node]]\n' "$0" >&2
    exit 2
    ;;
esac

# The options of the deploy's two modes, `native` and `build`:
# --without-postgres, for a wiki-server built without PostgreSQL. Both
# modes then leave libpq-dev out of the Debian packages (system_packages),
# and the maker's check of the native build is given the option, so that
# such a build is not stopped for want of libpq. `all` and `toolchain`, the
# everyday install for working on the wiki, always ask for libpq-dev.
# `native` also takes --with-wizard, for the configuration wizard
# (toolchain/configure.sh): libncurses-dev joins the Debian packages, and
# the check checks terminfo. The deploy never gives it.
# native, static and node also take --system-tools, and native, static and
# build --hackage-mirror=URL (see above); env takes --system-tools, for the
# lines of an environment without the bootstrap's own tools. native and
# build, the modes the deploy builds libsodium in, take
# --libsodium-source=FILE (see above).
check_postgres=
check_wizard=
system_tools=
hackage_mirror=
libsodium_source=
case $mode in
  native) usage_options='[--without-postgres] [--with-wizard] [--system-tools] [--hackage-mirror=URL] [--libsodium-source=FILE]' ;;
  build) usage_options='[--without-postgres] [--hackage-mirror=URL] [--libsodium-source=FILE]' ;;
  static | maker) usage_options='[--system-tools] [--hackage-mirror=URL]' ;;
  *) usage_options='[--system-tools]' ;;
esac
if [ "$mode" = native ] || [ "$mode" = build ] || [ "$mode" = static ] || [ "$mode" = maker ] || [ "$mode" = node ] || [ "$mode" = env ]; then
  shift
  for option do
    case $mode:$option in
      native:--without-postgres | build:--without-postgres) check_postgres=--without-postgres ;;
      native:--with-wizard) check_wizard=--with-wizard ;;
      native:--system-tools | static:--system-tools | maker:--system-tools | node:--system-tools | env:--system-tools) system_tools=1 ;;
      build:--system-tools)
        printf 'bootstrap: build takes no --system-tools: the page'"'"'s build needs the wasm toolchain, which the bootstrap installs (--system-tools is for native and node)\n' >&2
        exit 2
        ;;
      native:--hackage-mirror=* | build:--hackage-mirror=* | static:--hackage-mirror=* | maker:--hackage-mirror=*) hackage_mirror=${option#*=} ;;
      native:--libsodium-source=* | build:--libsodium-source=*)
        libsodium_source=${option#*=}
        [ -n "$libsodium_source" ] || {
          printf 'bootstrap: --libsodium-source=FILE needs the file: libsodium-%s.tar.gz, the release'"'"'s tarball\n' "$LIBSODIUM_VERSION" >&2
          exit 2
        }
        ;;
      *)
        printf 'usage: %s %s %s\n' "$0" "$mode" "$usage_options" >&2
        exit 2
        ;;
    esac
  done
fi
# The mirror is written into the toolchain's own cabal configuration, which
# exists only under a named WIKI_TOOLCHAIN_HOME: in the home directory,
# cabal's configuration is the user's own, which this script leaves alone.
case $hackage_mirror in
  '') ;;
  *[[:space:]\"\'\\\`\$]*)
    printf 'bootstrap: --hackage-mirror=%s: an http:// or https:// URL without spaces or quotes\n' "$hackage_mirror" >&2
    exit 2
    ;;
  http://?* | https://?*)
    if [ -z "$NAMED_BASE" ]; then
      printf "bootstrap: --hackage-mirror writes the mirror into the toolchain's own cabal configuration, which exists only under a WIKI_TOOLCHAIN_HOME other than the home directory; cabal's configuration in the home directory is yours, and this script does not change it\n" >&2
      exit 2
    fi
    ;;
  *)
    printf 'bootstrap: --hackage-mirror=%s: an http:// or https:// URL, such as https://hackage.example.org/\n' "$hackage_mirror" >&2
    exit 2
    ;;
esac

# libsodium's tarball given by hand must be there now, before anything is
# installed, rather than when the maker comes to it; it is named by absolute
# path from here on, since the maker runs toolchain/libsodium.sh from
# another directory.
if [ -n "$libsodium_source" ]; then
  if [ ! -f "$libsodium_source" ] || [ ! -r "$libsodium_source" ]; then
    printf 'bootstrap: --libsodium-source=%s: no such file here (or it cannot be read); give libsodium-%s.tar.gz, the release'"'"'s tarball\n' "$libsodium_source" "$LIBSODIUM_VERSION" >&2
    exit 2
  fi
  libsodium_source=$(realpath "$libsodium_source")
fi

# Where ghcup puts its symlinks: the bin directory of a ghcup already on PATH,
# or the default one this script installs into. Under a named directory the
# ghcup is that directory's own, whatever is on PATH, so that nothing is
# installed elsewhere.
if [ -n "$NAMED_BASE" ]; then
  GHCUP_BIN=$BASE/.ghcup/bin
  GHCUP=$GHCUP_BIN/ghcup
elif [ "$mode" != ready ] && command -v ghcup >/dev/null 2>&1; then
  GHCUP=$(command -v ghcup)
  GHCUP_BIN=$("$GHCUP" whereis bindir)
else
  GHCUP_BIN=${GHCUP_INSTALL_BASE_PREFIX:-$HOME}/.ghcup/bin
  GHCUP=$GHCUP_BIN/ghcup
fi

# The lines a shell needs to find ghcup's tools and this Node first. Written as
# literal paths so they are right whenever they are read, even before the
# install they point at has finished. With --system-tools the tools are the
# machine's own, and nothing is put first on PATH.
env_lines() {
  if [ -n "$system_tools" ]; then
    printf "# Written by toolchain/bootstrap.sh --system-tools: GHC, cabal and Node are this machine's own, as PATH finds them.\n"
  else
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
  fi
  # libsodium, which toolchain/libsodium.sh builds into the toolchain's
  # directory (the maker runs it in every mode that builds natively, with
  # --system-tools too): its directories go first, so that pkg-config, the
  # C compiler and the linker find the pinned static library before any
  # libsodium the system has. Each is added once, however often the file
  # is read.
  cat <<EOF
# libsodium $LIBSODIUM_VERSION, built from source by toolchain/libsodium.sh, ahead of any the system has.
case :\${PKG_CONFIG_PATH:-}: in *:"$STATE/libsodium/lib/pkgconfig":*) ;; *) PKG_CONFIG_PATH="$STATE/libsodium/lib/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}" ;; esac
case :\${LIBRARY_PATH:-}: in *:"$STATE/libsodium/lib":*) ;; *) LIBRARY_PATH="$STATE/libsodium/lib\${LIBRARY_PATH:+:\$LIBRARY_PATH}" ;; esac
case :\${C_INCLUDE_PATH:-}: in *:"$STATE/libsodium/include":*) ;; *) C_INCLUDE_PATH="$STATE/libsodium/include\${C_INCLUDE_PATH:+:\$C_INCLUDE_PATH}" ;; esac
export PKG_CONFIG_PATH LIBRARY_PATH C_INCLUDE_PATH
EOF
  [ -z "$NAMED_BASE" ] || cat <<EOF
# The toolchain is under $BASE, and the tools keep their files there too.
WIKI_TOOLCHAIN_HOME='$BASE'
GHCUP_INSTALL_BASE_PREFIX='$BASE'
CABAL_DIR='$BASE/.cabal'
npm_config_cache='$BASE/.npm'
PLAYWRIGHT_BROWSERS_PATH='$BASE/.cache/ms-playwright'
export WIKI_TOOLCHAIN_HOME GHCUP_INSTALL_BASE_PREFIX CABAL_DIR npm_config_cache PLAYWRIGHT_BROWSERS_PATH
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
# With --system-tools, and for its check alone, only the machine's own
# tools count.
if [ "$mode" != ready ] && [ "$mode" != system-tools ] && [ -z "$system_tools" ]; then
  PATH=$STATE/node/bin:$GHCUP_BIN:$PATH
  export PATH
fi

numeric_version() {
  "$1" --numeric-version 2>/dev/null || true
}

compatible_node() {
  node_major=$(node --version 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\)\..*/\1/p')
  [ -n "$node_major" ] && [ "$node_major" -ge "$NODE_MIN_MAJOR" ] && command -v npm >/dev/null 2>&1
}

# --- The machine's own tools (--system-tools) --------------------------------
#
# With --system-tools the bootstrap installs no GHC, cabal or Node, and these
# check the machine's own on PATH before anything else runs: each is named
# with the version found, one that is not the pinned version gets a warning
# (only the pins are tested), and one that is missing or older than its
# floor (GHC_MIN_VERSION, CABAL_MIN_VERSION, NODE_MIN_MAJOR) stops the run.

# Whether the version $1 is $2 or later, comparing their numbers one by one
# (9.12.2 is 9.12 or later, 9.10.3 is not); a number missing counts as 0.
version_at_least() {
  awk -v found="$1" -v floor="$2" 'BEGIN {
    split(found, f, "."); m = split(floor, g, ".")
    for (i = 1; i <= m; i++) {
      if (f[i] + 0 > g[i] + 0) exit 0
      if (f[i] + 0 < g[i] + 0) exit 1
    }
    exit 0
  }'
}

# One of the machine's compilers: $1 the command, $2 its name, $3 the
# pinned version, $4 the floor, $5 why the floor is what it is. Sets
# system_missing when it will not do.
system_tool() {
  found=$(numeric_version "$1")
  if [ -z "$found" ]; then
    printf 'bootstrap: --system-tools: %s: not found (no %s on PATH answers --numeric-version). %s %s or later is needed: %s. Without --system-tools, toolchain/bootstrap.sh installs %s %s\n' \
      "$2" "$1" "$2" "$4" "$5" "$2" "$3" >&2
    system_missing=1
  elif ! version_at_least "$found" "$4"; then
    printf 'bootstrap: --system-tools: %s %s (%s) is too old: %s %s or later is needed: %s. Without --system-tools, toolchain/bootstrap.sh installs %s %s\n' \
      "$2" "$found" "$(command -v "$1")" "$2" "$4" "$5" "$2" "$3" >&2
    system_missing=1
  else
    printf 'bootstrap: --system-tools: %s %s (%s)\n' "$2" "$found" "$(command -v "$1")"
    [ "$found" = "$3" ] ||
      printf "bootstrap: warning: the pinned %s is %s; the build with %s is untested here and may fail; a failure then is not this script's\n" "$2" "$3" "$found" >&2
  fi
}

# The machine's Node and npm, for the npm scripts, the page's bundles and
# the demo's server. Sets system_missing when they will not do.
system_node() {
  found=$(node --version 2>/dev/null || true)
  found_major=$(printf '%s' "$found" | sed -n 's/^v\([0-9][0-9]*\)\..*/\1/p')
  without="Without --system-tools, toolchain/bootstrap.sh installs Node $NODE_VERSION, with its npm"
  if [ -z "$found" ]; then
    printf 'bootstrap: --system-tools: Node: not found (no node on PATH answers --version). Node %s or later with npm is needed. %s\n' "$NODE_MIN_MAJOR" "$without" >&2
    system_missing=1
  elif [ -z "$found_major" ] || [ "$found_major" -lt "$NODE_MIN_MAJOR" ]; then
    printf 'bootstrap: --system-tools: Node %s (%s) is too old: Node %s or later with npm is needed. %s\n' "$found" "$(command -v node)" "$NODE_MIN_MAJOR" "$without" >&2
    system_missing=1
  elif ! command -v npm >/dev/null 2>&1; then
    printf 'bootstrap: --system-tools: npm: not found on PATH beside Node %s (%s); Node %s or later with npm is needed. %s\n' "$found" "$(command -v node)" "$NODE_MIN_MAJOR" "$without" >&2
    system_missing=1
  else
    printf 'bootstrap: --system-tools: Node %s (%s), npm %s (%s)\n' "$found" "$(command -v node)" "$(npm --version 2>/dev/null || true)" "$(command -v npm)"
  fi
}

# Check what a run needs of the machine's own tools: native (GHC and
# cabal) and node (Node and npm), as arguments. Fails, after naming every
# tool that will not do, when one will not.
check_system_tools() {
  system_missing=
  for need do
    case $need in
      # static: GHC and cabal for the maker, and Node for the demo; maker:
      # GHC and cabal alone.
      native | static | maker)
        system_tool ghc GHC "$GHC_VERSION" "$GHC_MIN_VERSION" "haskell-halogen, which the wiki builds with, is tested with GHC $GHC_MIN_VERSION and later, and its th package asks for ghc $GHC_MIN_VERSION or later"
        system_tool cabal cabal "$CABAL_VERSION" "$CABAL_MIN_VERSION" "cabal.project sets semaphore:, a field cabal reads from $CABAL_MIN_VERSION"
        [ "$need" != static ] || system_node
        ;;
      node) system_node ;;
    esac
  done
  if [ -n "$system_missing" ]; then
    printf 'bootstrap: --system-tools: this machine lacks what is named above, so nothing was installed or changed\n' >&2
    return 1
  fi
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
  if sh "$ROOT/toolchain/libsodium.sh" ready "$STATE"; then
    printf 'bootstrap: reuse libsodium %s (%s)\n' "$LIBSODIUM_VERSION" "$STATE/libsodium-$LIBSODIUM_VERSION"
  else
    printf 'bootstrap: install libsodium %s (built from source)\n' "$LIBSODIUM_VERSION"
  fi
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

# Do not launch Chromium here: its cache can be checked without creating a
# browser profile or lock files. Install mode verifies runtime libraries by
# launching it. Wasm's env is loaded only in a subshell, as the build does,
# so native tools are checked before its CC and PATH can take over.
#
# Each command is checked for what it needs and nothing more, since a machine
# need not hold the whole toolchain: the native commands need the host GHC and
# cabal only (a hosted CI runner has just those for the native job); the wasm
# builds need the wasm sysroot, Node and the npm packages as well; the test
# commands that open a browser need Chromium on top. fourmolu is nobody's:
# `npm run format` runs it directly, and `check` reports it.
ready() {
  target=${2:-build-wasm}
  case $target in
    build-native | test-native) needs=native ;;
    build-wasm | build-wasm-opt | serve-wasm) needs=wasm ;;
    test-wasm | test | dev-test) needs=browser ;;
    *) printf 'bootstrap: unknown readiness target: %s\n' "$target" >&2; return 2 ;;
  esac
  ready_failed=0
  ready_context=
  require_version ghc "$GHC_VERSION"
  require_version cabal "$CABAL_VERSION"
  if [ "$needs" = native ]; then
    ready_done "$target"
    return $?
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
    if [ "$needs" = browser ]; then
      playwright_location
      location=
      if [ -n "$cli" ]; then
        location=$(node "$cli" install --dry-run --only-shell chromium 2>/dev/null | sed -n 's/^ *Install location: *//p' | head -n 1)
      fi
      if [ -z "$location" ] || ! chromium_cached; then
        printf 'bootstrap: not ready: Chromium headless shell for Playwright %s is missing.\n' "$version" >&2
        ready_failed=1
      fi
    fi
    if ! node "$ROOT/toolchain/check-npm-deps.cjs" "$ROOT" "$target"; then
      ready_failed=1
    fi
  fi
  ready_done "$target"
}

ready_done() {
  if [ "$ready_failed" != 0 ]; then
    # shellcheck disable=SC2088 # the tilde is for the reader, as the message is.
    if [ -n "$NAMED_BASE" ]; then env_hint=$STATE/env; else env_hint='~/.wiki-toolchain/env'; fi
    printf 'bootstrap: run `sh toolchain/bootstrap.sh toolchain`, then retry. npm build, serve and test commands load %s automatically; for direct commands, load `. %s` in this shell.\n' "$env_hint" "$env_hint" >&2
    return 1
  fi
  printf 'bootstrap: ready for %s.\n' "$1"
}

if [ "$mode" = ready ]; then
  ready "$@"
  exit $?
fi

if [ "$mode" = check ]; then
  check
  exit $?
fi

# The check of the machine's own tools, alone (toolchain/deploy-local.sh
# --system-tools runs it before anything else), or as the first thing of
# native --system-tools and node --system-tools.
if [ "$mode" = system-tools ]; then
  shift
  [ $# -gt 0 ] || set -- native node
  for need do
    case $need in
      native | node) ;;
      *)
        printf 'usage: %s system-tools [native] [node]\n' "$0" >&2
        exit 2
        ;;
    esac
  done
  check_system_tools "$@"
  exit $?
fi
if [ -n "$system_tools" ]; then
  check_system_tools "$mode" || exit 1
fi

# setup.sh deletes its prefix: refuse unsafe state before changing anything.
# A native, static or node install never runs it, and leaves ~/.ghc-wasm alone.
case $mode in
  native | static | maker | node) ;;
  *) guard_wasm_sysroot || exit 1 ;;
esac
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

# Run a long step (ghcup installing a compiler, cabal updating its index,
# the wasm sysroot's setup) as run does. In the modes
# toolchain/deploy-local.sh uses, native and build, its output is also shown
# as it comes, so that a deploy does not sit silent for minutes. The other
# modes, which the SessionStart hooks use, keep it in the log alone.
run_long() {
  case $mode in
    native | static | maker | build) ;;
    *)
      run "$@"
      return 0 ;;
  esac
  step=$1
  shift
  printf '+ %s\n' "$*" >>"$LOG"
  # A pipeline's status is tee's, so the command's own status goes to a
  # file, which stays empty when the command succeeds.
  status_file=$(mktemp)
  { "$@" 2>&1 || printf '%s' "$?" >"$status_file"; } | tee -a "$LOG"
  failed=$(cat "$status_file")
  rm -f "$status_file"
  [ -z "$failed" ] || fail "$step"
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

# The Debian packages GHC itself needs, before there is a GHC to build the
# maker: a C toolchain and make (GHC compiles and links with them;
# build-essential), GMP's development files (every native program links
# libgmp), and curl and xz, with which ghcup and the downloads are fetched
# and unpacked. GHC also loads libtinfo, which every Debian has (bash needs
# it). The packages of the builds' own C libraries, and those the wasm
# sysroot's setup runs, are the maker's (maker/src/Maker/Toolchain/Debian.hs),
# which installs them first thing. On another system nothing is installed:
# the commands are checked, and GMP's header is left to the maker's check.
system_packages() {
  missing=
  debian_packages='build-essential curl libgmp-dev xz-utils'
  if command -v dpkg-query >/dev/null 2>&1; then
    for pkg in $debian_packages; do
      if ! dpkg-query -W -f '${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
        missing="$missing $pkg"
      fi
    done
  else
    for cmd in cc make curl tar xz; do
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
    run_long "installing $tool $version" "$@"
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

# The commands install_node downloads and unpacks Node with, checked by the
# node mode before a download needs them: that mode installs no system
# packages, so a missing command is named here rather than failing halfway.
node_commands() {
  compatible_node && return 0
  [ "$("$NODE_DIR/bin/node" --version 2>/dev/null || true)" != "v$NODE_VERSION" ] || return 0
  missing=
  for cmd in curl tar xz; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
  done
  if [ -n "$missing" ]; then
    say "missing commands:$missing; install them and run this again (Node is downloaded with curl and unpacked with tar and xz)"
    exit 1
  fi
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

# --- Hackage's mirror (--hackage-mirror) -------------------------------------
#
# The toolchain's own cabal configuration ($CABAL_DIR/config, under a named
# WIKI_TOOLCHAIN_HOME only) can name a mirror of Hackage as the url of its
# repository hackage.haskell.org, from which cabal then fetches the index
# and every package. The repository keeps its name, so plans and the store
# are as with Hackage itself. It stays secure (secure: True): for the
# repository of that name cabal knows Hackage's root keys, and checks the
# index against Hackage's signatures, whoever serves it. So the mirror must
# serve Hackage's signed metadata (root.json, timestamp.json,
# snapshot.json, mirrors.json) beside the index and the packages, as a full
# mirror does (hackage-mirror-tool's, or a proxy that passes Hackage
# through). A mirror without them is refused before anything is written:
# its root.json is fetched first. The lines written carry a comment
# (HACKAGE_MARK), so that a run without the option puts Hackage's own url
# back. HACKAGE_URL is the url cabal's own default configuration has.
HACKAGE_URL=http://hackage.haskell.org/
HACKAGE_MARK='-- url: written by toolchain/bootstrap.sh --hackage-mirror'

# The url of the repository hackage.haskell.org in a cabal configuration.
hackage_url() {
  awk '$0 == "repository hackage.haskell.org" { inside = 1; next }
    inside && /^[ \t]/ { if ($1 == "url:") { print $2; exit } next }
    { inside = 0 }' "$1" 2>/dev/null
}

# Write the mirror (or Hackage's own url, when a mirror was written before
# and none is given now) into the toolchain's cabal configuration, which
# cabal user-config init writes first when there is none. Sets
# hackage_changed when the url changed, so that the index is fetched again
# from the new place.
hackage_config() {
  hackage_changed=
  [ -n "$NAMED_BASE" ] || return 0
  config=$CABAL_DIR/config
  if [ -z "$hackage_mirror" ] && ! grep -qF -- "$HACKAGE_MARK" "$config" 2>/dev/null; then
    return 0
  fi
  url=${hackage_mirror:-$HACKAGE_URL}
  case $url in */) ;; *) url=$url/ ;; esac
  if [ "$(hackage_url "$config")" = "$url" ] && grep -qF -- "$HACKAGE_MARK" "$config" 2>/dev/null; then
    return 0
  fi
  if [ -n "$hackage_mirror" ]; then
    printf '+ fetch %sroot.json\n' "$url" >>"$LOG"
    if ! fetch "${url}root.json" "$STATE/hackage-root.json" >>"$LOG" 2>&1; then
      rm -f "$STATE/hackage-root.json"
      say "the Hackage mirror $url does not serve root.json (the end of $LOG says why): cabal checks Hackage's index against Hackage's own keys, so the mirror must serve Hackage's signed metadata (root.json, timestamp.json, snapshot.json, mirrors.json) as a full mirror does; nothing was changed"
      exit 1
    fi
    rm -f "$STATE/hackage-root.json"
  fi
  if [ ! -f "$config" ]; then
    run "writing cabal's configuration" sh -c "cd '$STATE' && cabal user-config init"
  fi
  awk -v url="$url" -v mirror="$hackage_mirror" -v mark="$HACKAGE_MARK" '
    function lines() {
      print "  url: " url
      if (mirror != "") { print "  secure: True"; print "  " mark }
    }
    $0 == "repository hackage.haskell.org" { print; lines(); inside = 1; found = 1; next }
    inside && /^[ \t]/ {
      if ($1 == "url:" || $1 == "secure:" || index($0, mark)) next
      print
      next
    }
    { inside = 0; print }
    END { if (!found) { print ""; print "repository hackage.haskell.org"; lines() } }
  ' "$config" >"$config.tmp" && mv "$config.tmp" "$config"
  if [ -n "$hackage_mirror" ]; then
    say "cabal's index and packages come from the Hackage mirror $url: written into $config"
  else
    say "cabal's index and packages come from Hackage again: its url written back into $config"
  fi
  hackage_changed=1
}

update_cabal_index() {
  hackage_config
  index=$(cd "$STATE" && cabal path --remote-repo-cache 2>>"$LOG")/hackage.haskell.org/01-index.tar
  if [ ! -f "$index" ] || [ -n "$hackage_changed" ]; then
    say "updating cabal's package index"
    run_long "updating cabal's package index" sh -c "cd '$STATE' && cabal update"
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
  if [ "$mode" = node ]; then
    if [ -z "$system_tools" ]; then
      node_commands
      install_node
    fi
    write_env
    summary="Node $(node --version); no compilers, wasm toolchain, Chromium or fourmolu (node)"
    [ -z "$system_tools" ] || summary="this machine's Node $(node --version) (--system-tools); no compilers, wasm toolchain, Chromium or fourmolu (node)"
    if [ "$(wc -c <"$LOG")" = "$quiet_before" ]; then
      printf 'bootstrap: toolchain already installed (%s)\n' "$summary"
    else
      say "toolchain ready in $(($(date +%s) - started))s: $summary"
    fi
    return 0
  fi
  system_packages
  [ -n "$system_tools" ] || install_native
  # The index first: the maker is built from Hackage's packages, or the
  # mirror's.
  update_cabal_index
  write_env
  # maker: the maker is built, for toolchain/deploy-local.sh to run, and
  # nothing more is installed; the deploy runs the mode it needs after.
  if [ "$mode" = maker ]; then
    build_maker
    say "GHC and cabal are ready, and the maker is built"
    return 0
  fi
  hand_over
}

# The second stage, the maker (maker/): with GHC and cabal there, it
# installs the rest of the toolchain (the builds' system packages, the wasm
# sysroot and cross compiler, Node, Chromium and fourmolu, as the mode asks;
# for native the system packages alone, then the check of the native
# build), prints the summary, and for all and warm builds the repository's
# dependencies into the cabal store. The options of native and build go
# with it. It is built with its own cabal project (maker/cabal.project), once
# and kept, and takes over this process, which still holds the toolchain's
# lock on descriptor 9. WIKI_MAKER names a maker built elsewhere: the
# bootstrap's tests run it against a fake cabal, which builds nothing.
build_maker() {
  maker=${WIKI_MAKER:-}
  if [ -z "$maker" ]; then
    maker=$(cd "$ROOT/maker" && cabal list-bin -v0 exe:maker 2>>"$LOG") || fail "finding the maker's binary (maker/)"
    [ -x "$maker" ] || say "building the maker (maker/; once, later runs reuse it)"
    # A long step: in the deploy's modes its progress (the maker's
    # libraries, then its modules) is shown as it comes, and it is logged.
    run_long "building the maker (cd maker && cabal build exe:maker)" sh -c 'cd "$1/maker" && cabal build exe:maker' sh "$ROOT"
  fi
}
hand_over() {
  build_maker
  exec "$maker" bootstrap "$mode" --root "$ROOT" --base "$BASE" ${NAMED_BASE:+--named-base} \
    --ghcup-bin "$GHCUP_BIN" --log-size "$quiet_before" --started "$started" --lock-fd 9 \
    ${check_postgres:+--without-postgres} ${check_wizard:+--with-wizard} ${system_tools:+--system-tools} \
    ${libsodium_source:+"--libsodium-source=$libsodium_source"}
}

# --- Main -------------------------------------------------------------------

printf '\n=== %s bootstrap %s (%s)\n' "$(date '+%F %T')" "$mode" "$ROOT" >>"$LOG"

# The toolchain's lock, held through the maker's part of the run, which lets
# it go before it warms the store under a lock of its own: a run that is only
# warming the store does not hold up one that only wants the toolchain.
(
  lock toolchain
  toolchain
) 9>"$STATE/toolchain.lock"

