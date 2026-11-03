#!/bin/sh
# Check what the native build of wiki-server needs from the machine, before
# anything is downloaded or built.
#
#   sh toolchain/check-native.sh [--help]
#
# It prints one line per item, ok or missing, with how the item was found or
# what was tried, and then a summary. It exits 0 when everything is there and
# 1 when something is missing. It installs nothing and changes nothing.
#
# toolchain/deploy-local.sh runs it first whenever it builds wiki-server, and
# toolchain/bootstrap.sh native runs it after installing the Debian packages.
# Without it, a missing C library shows up only as a link error deep in a
# cabal build, after the downloads and the compilers.
#
# The items, and how the build finds each one:
#
#   - the commands cc, make, curl, git and pkg-config, on PATH;
#   - GMP, which every native GHC program links with: its header gmp.h,
#     through the C compiler;
#   - libpq, for PostgreSQL: postgresql-libpq's configure script asks
#     pg_config, and pkg-config's libpq.pc does as well;
#   - zlib, for the zlib package, which is built without its bundled copy and
#     finds the system's zlib through pkg-config (zlib.pc);
#   - libsodium, for the second factor's codes: libsodium-bindings does not
#     use pkg-config, so cabal includes sodium.h and links -lsodium from the
#     compiler's own directories and those LIBRARY_PATH and C_INCLUDE_PATH
#     name. The check compiles and links a one-line program the same way.
#
# SQLite is not an item: direct-sqlite builds its own copy of SQLite.
#
# The build sees the environment this script runs in. LIBRARY_PATH,
# C_INCLUDE_PATH, CPATH and PKG_CONFIG_PATH reach cabal untouched, so a
# library installed into a directory of one's own is checked here as the
# build will find it.
set -eu

usage() {
  printf 'usage: sh toolchain/check-native.sh [--help]\n'
}

case ${1:-} in
  '') ;;
  -h | --help)
    usage
    printf '\nChecks the commands and C libraries the native build of wiki-server needs\n'
    printf '(cc, make, curl, git, pkg-config, GMP, libpq, zlib, libsodium), one line each,\n'
    printf 'and exits 1 when one is missing. It installs nothing.\n'
    exit 0 ;;
  *)
    usage >&2
    exit 2 ;;
esac

checked=0
missing=
debian=
rhel=

# Print one item's line. The arguments are the item, ok or missing, and how
# it was found or what was tried.
report() {
  checked=$((checked + 1))
  printf '%-8s %-11s %s\n' "$2" "$1" "$3"
}

# Record a missing item with its Debian and RHEL packages, for the summary.
lack() {
  missing="${missing:+$missing, }$1"
  debian="${debian:+$debian }$2"
  rhel="${rhel:+$rhel }$3"
  report "$1" missing "$4 (Debian: $2; RHEL: $3)"
}

has() { command -v "$1" >/dev/null 2>&1; }

# The commands. A command is only looked up, never run: running one is the
# build's business.
command_item() {
  if path=$(command -v "$1" 2>/dev/null); then
    report "$1" ok "$path"
  else
    lack "$1" "$2" "$3" "not on PATH"
  fi
}
command_item cc build-essential gcc
command_item make make make
command_item curl curl curl
command_item git git git
command_item pkg-config pkg-config pkgconf-pkg-config

# GMP's header, through the C compiler's preprocessor.
if ! has cc; then
  lack GMP libgmp-dev gmp-devel "not checked: needs cc"
elif printf '#include <gmp.h>\n' | cc -E -x c - >/dev/null 2>&1; then
  report GMP ok "gmp.h, through cc -E"
else
  lack GMP libgmp-dev gmp-devel "cc -E finds no gmp.h"
fi

# libpq: pg_config is what postgresql-libpq's configure script asks.
if path=$(command -v pg_config 2>/dev/null); then
  report libpq ok "pg_config at $path"
elif has pkg-config && pkg-config --exists libpq; then
  report libpq ok "pkg-config --exists libpq"
else
  lack libpq libpq-dev libpq-devel "neither pg_config on PATH nor pkg-config's libpq"
fi

# zlib, through pkg-config, as the zlib package finds it.
if ! has pkg-config; then
  lack zlib zlib1g-dev zlib-devel "not checked: needs pkg-config"
elif pkg-config --exists zlib; then
  report zlib ok "pkg-config --exists zlib"
else
  lack zlib zlib1g-dev zlib-devel "pkg-config --exists zlib failed"
fi

# libsodium, compiled and linked as the build does it. The program is
# written into a directory of its own and removed afterwards. When the link
# fails but pkg-config knows a libsodium, the hint says which directories to
# give the build.
sodium_hint=
if ! has cc; then
  lack libsodium libsodium-dev libsodium-devel "not checked: needs cc"
else
  probe=$(mktemp -d)
  trap 'rm -rf "$probe"' EXIT
  printf '#include <sodium.h>\nint main(void) { return sodium_init() < 0; }\n' >"$probe/sodium.c"
  if cc -o "$probe/sodium" "$probe/sodium.c" -lsodium >"$probe/cc.log" 2>&1; then
    report libsodium ok "sodium.h and -lsodium, through cc"
  else
    if has pkg-config && pkg-config --exists libsodium; then
      libdir=$(pkg-config --variable=libdir libsodium 2>/dev/null || true)
      includedir=$(pkg-config --variable=includedir libsodium 2>/dev/null || true)
      sodium_hint="pkg-config finds a libsodium${libdir:+ in $libdir}, but cc does not: the build looks where cc does, so give it LIBRARY_PATH=${libdir:-<its lib>} C_INCLUDE_PATH=${includedir:-<its include>}"
    fi
    lack libsodium libsodium-dev libsodium-devel "cc cannot compile and link a program with sodium.h and -lsodium"
  fi
  rm -rf "$probe"
  trap - EXIT
fi

if [ -z "$missing" ]; then
  printf 'All %s items the native build of wiki-server needs are there.\n' "$checked"
  exit 0
fi

printf '\nMissing for the native build of wiki-server: %s.\n' "$missing"
printf 'Install them and run this again:\n'
printf '    Debian, Ubuntu: sudo apt-get install %s\n' "$debian"
printf '    RHEL, Fedora:   sudo dnf install %s\n' "$rhel"
case $missing in
  *libsodium*)
    [ -z "$sodium_hint" ] || printf '%s.\n' "$sodium_hint"
    printf 'RHEL has libsodium in EPEL only. Built from source into a directory <dir> of your own:\n'
    printf '    ./configure --prefix=<dir> --disable-shared --enable-static --with-pic && make install\n'
    printf '    then run with LIBRARY_PATH=<dir>/lib C_INCLUDE_PATH=<dir>/include PKG_CONFIG_PATH=<dir>/lib/pkgconfig\n' ;;
esac
printf 'The build sees the environment this runs in: LIBRARY_PATH, C_INCLUDE_PATH, CPATH\n'
printf 'and PKG_CONFIG_PATH reach cabal untouched, for a library in a directory of its own.\n'
printf 'A shared library there also needs LD_LIBRARY_PATH when wiki-server runs\n'
printf '(toolchain/deploy-local.sh writes it into the systemd unit).\n'
exit 1
