#!/bin/sh
# Build libsodium from source, as a static library, into the toolchain's
# directory, and say where it is.
#
#   sh toolchain/libsodium.sh install [STATE [FILE]]
#                                               # download, check, build and install, unless it is there
#   sh toolchain/libsodium.sh ready [STATE]     # read-only: exit 0 when it is installed, 1 when not
#   sh toolchain/libsodium.sh env [STATE]       # KEY=VALUE lines of the variables a build needs
#
# STATE is the toolchain's own directory, ~/.wiki-toolchain by default (or
# $WIKI_TOOLCHAIN_HOME/.wiki-toolchain, as for toolchain/bootstrap.sh).
#
# The native build links libsodium for two packages: sel's bindings
# (libsodium-bindings), for the second factor's codes, and opaque, the
# server's side of OPAQUE. opaque needs
# libsodium 1.0.19 or later for its HKDF, and Debian and Ubuntu ship 1.0.18.
# So every native build (a developer's, CI's, the deploy's and the Docker
# image's) uses the one release pinned in toolchain/pins.env
# (LIBSODIUM_VERSION, checked against LIBSODIUM_SHA256), built here. It is
# built without a shared library (--disable-shared), so the linker can only
# take the static archive, and wiki-server carries libsodium inside its
# binary: the machine it runs on needs no libsodium package. --with-pic,
# because GHC links position-independent executables.
#
# It goes into STATE/libsodium-<version>, and STATE/libsodium is a link to
# it. The environment file toolchain/bootstrap.sh writes names the link's
# lib, include and lib/pkgconfig directories in LIBRARY_PATH,
# C_INCLUDE_PATH and PKG_CONFIG_PATH, ahead of the system's; `env` prints
# the same variables for CI's $GITHUB_ENV.
#
# Both packages find it through pkg-config (cabal.project turns on
# libsodium-bindings' flag pkg-config), and the libsodium.pc installed here
# is rewritten to name the library libsodium-static, a link to libsodium.a
# that exists nowhere else. The name matters on a machine with Debian's
# libsodium-dev: cabal registers /usr/lib/x86_64-linux-gnu as a library
# directory of every package found through pkg-config (zlib's among them),
# GHC passes those directories to the linker in an order nobody chooses,
# and -lsodium would then find the system's libsodium.so (1.0.18, without
# HKDF) before this one. -lsodium-static is found only here. The .pc's
# prefix is the link STATE/libsodium rather than the versioned directory,
# so that what cabal records stays right when the version changes.
#
# The install is complete only when the file .built in it holds the version
# and checksum, which is written last: an install that was interrupted is
# started again from nothing by the next run.
#
# The maker runs `install` for the bootstrap's modes that build natively
# (all, toolchain, build, warm, native), and CI runs it on hosted runners,
# which do not run the bootstrap, with the installed directory cached.
# The release comes from download.libsodium.org, or where that host is
# refused, from the same release on GitHub; both serve the same file, and
# the checksum is checked either way. FILE is the release's tarball
# (libsodium-<version>.tar.gz) brought onto the machine by hand, for a
# machine that downloads nothing (the bootstrap's --libsodium-source): it
# is copied instead of downloaded, and its checksum is checked the same
# way. The file itself is left as it is. Building it needs a C compiler,
# make, tar and gzip, and curl when there is no FILE, and takes under a
# minute.
set -eu

# shellcheck source=toolchain/pins.env
. "$(cd "$(dirname "$0")" && pwd)/pins.env"

usage() {
  printf 'usage: sh toolchain/libsodium.sh install [STATE [FILE]] | ready [STATE] | env [STATE]\n' >&2
  exit 2
}

if [ $# -lt 1 ] || [ $# -gt 3 ]; then usage; fi
mode=$1
[ $# -lt 3 ] || [ "$mode" = install ] || usage
STATE=${2:-${WIKI_TOOLCHAIN_HOME:-$HOME}/.wiki-toolchain}
# The release's tarball given by hand, used instead of a download.
SOURCE=${3:-}
DIR=$STATE/libsodium-$LIBSODIUM_VERSION
LINK=$STATE/libsodium
MARK="$LIBSODIUM_VERSION $LIBSODIUM_SHA256"

say() { printf 'libsodium: %s\n' "$*"; }

# Whether this version is installed completely, whatever the link says.
built() {
  [ "$(cat "$DIR/.built" 2>/dev/null || true)" = "$MARK" ] &&
    [ -f "$DIR/lib/libsodium.a" ] &&
    [ -f "$DIR/lib/libsodium-static.a" ] &&
    [ -f "$DIR/include/sodium.h" ] &&
    [ -f "$DIR/lib/pkgconfig/libsodium.pc" ]
}

# Whether it is installed and the link points at it.
ready() {
  built && [ "$(readlink "$LINK" 2>/dev/null || true)" = "$DIR" ]
}

fetch() {
  curl --fail --location --retry 5 --silent --show-error --output "$2" "$1"
}

install() {
  if ! built; then
    if [ -n "$SOURCE" ] && { [ ! -f "$SOURCE" ] || [ ! -r "$SOURCE" ]; }; then
      say "$SOURCE: no such file here (or it cannot be read); nothing was built"
      exit 1
    fi
    # curl only downloads, and a file given needs no download.
    fetcher=curl
    [ -z "$SOURCE" ] || fetcher=
    missing=
    for cmd in cc make $fetcher tar gzip sha256sum; do
      command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then
      say "missing commands:$missing; building libsodium needs them"
      exit 1
    fi
    say "building libsodium $LIBSODIUM_VERSION from source into $DIR"
    src=$DIR.src
    name=libsodium-$LIBSODIUM_VERSION.tar.gz
    if [ -n "$SOURCE" ]; then
      # The file given is copied before anything here is deleted, to a
      # name of its own, so that no clean-up below can remove it: it may
      # sit in STATE under the name a download would take. A file inside
      # the directories this install replaces is refused outright.
      given=$(realpath "$SOURCE")
      case $given in
        "$DIR"/* | "$src"/*)
          say "$SOURCE is inside $DIR, which the install replaces; put it elsewhere; nothing was built"
          exit 1
          ;;
      esac
      say "taking $name from $SOURCE instead of downloading it"
      mkdir -p "$STATE"
      archive=$(mktemp "$STATE/libsodium-given.XXXXXX")
      cp "$SOURCE" "$archive" || {
        say "copying $SOURCE failed; nothing was built"
        rm -f "$archive"
        exit 1
      }
      name=$SOURCE
      rm -rf "$DIR" "$src"
    else
      archive=$DIR.tar.gz
      rm -rf "$DIR" "$src" "$archive"
    fi
    mkdir -p "$src"
    if [ -n "$SOURCE" ]; then
      :
    elif ! fetch "https://download.libsodium.org/libsodium/releases/$name" "$archive"; then
      say "download.libsodium.org did not give $name; fetching the same release from GitHub"
      fetch "https://github.com/jedisct1/libsodium/releases/download/$LIBSODIUM_VERSION-RELEASE/$name" "$archive" || {
        say "downloading $name failed"
        rm -rf "$src" "$archive"
        exit 1
      }
    fi
    if ! printf '%s  %s\n' "$LIBSODIUM_SHA256" "$archive" | sha256sum --check --status; then
      say "$name does not have the checksum toolchain/pins.env pins (LIBSODIUM_SHA256); nothing was built"
      rm -rf "$src" "$archive"
      exit 1
    fi
    tar xzf "$archive" --strip-components=1 --directory "$src"
    jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 2)
    # The archive's own compiler flags (-O3 and the rest) stand; only the
    # kind of library is chosen. The cross compiler's CC, which
    # ~/.ghc-wasm/env exports, must not reach a native library.
    (
      cd "$src"
      unset CC CFLAGS LDFLAGS AR RANLIB
      ./configure --prefix="$DIR" --disable-shared --enable-static --with-pic --disable-dependency-tracking
      make -j"$jobs"
      make install
    )
    ln -s libsodium.a "$DIR/lib/libsodium-static.a"
    pc=$DIR/lib/pkgconfig/libsodium.pc
    {
      printf '# Rewritten by toolchain/libsodium.sh: the prefix is the link %s, and the\n' "$LINK"
      printf '# library is libsodium-static, a name no system library has (see that script).\n'
      # shellcheck disable=SC2016 # ${libdir} is the .pc file's own variable.
      sed -e "s|^prefix=.*|prefix=$LINK|" -e 's|^Libs: .*|Libs: -L${libdir} -lsodium-static|' "$pc"
    } >"$pc.tmp"
    mv "$pc.tmp" "$pc"
    printf '%s\n' "$MARK" >"$DIR/.built"
    rm -rf "$src" "$archive"
    built || {
      say "the install in $DIR is incomplete after make install"
      exit 1
    }
  fi
  if [ "$(readlink "$LINK" 2>/dev/null || true)" != "$DIR" ]; then
    ln -sfn "$DIR" "$LINK"
  fi
}

# The variables, each with the link's directory first and what the
# environment had after it.
env_lines() {
  printf 'PKG_CONFIG_PATH=%s\n' "$LINK/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  printf 'LIBRARY_PATH=%s\n' "$LINK/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
  printf 'C_INCLUDE_PATH=%s\n' "$LINK/include${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
}

case $mode in
  install) install ;;
  ready) ready ;;
  env) env_lines ;;
  *) usage ;;
esac
