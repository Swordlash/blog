#!/bin/sh
# Configure a deployment of the wiki in a terminal wizard, and run it:
# toolchain/configure.hs asks for toolchain/deploy-local.sh's options in a
# few screens, starting from the deployment's last run, shows the command
# line, and on Enter runs the deploy with it.
#
#   sh toolchain/configure.sh                   # the wizard
#   sh toolchain/configure.sh --args-from FILE  # print the command line FILE's answers make
#   sh toolchain/configure.sh --help
#
# The wizard is a Haskell program with brick, compiled on this machine as a
# cabal script, so this first gets what compiling it needs:
#
#   1. toolchain/check-native.sh --without-postgres --with-wizard checks the
#      C compiler and libraries, terminfo included (vty, under brick, links
#      libtinfo: Debian's libncurses-dev, RHEL's ncurses-devel). On Debian
#      or Ubuntu (dpkg-query on PATH) a missing package is a warning, since
#      the bootstrap installs it next; elsewhere this stops, naming the
#      packages. libpq is not checked: the wizard does not need it, and the
#      deploy checks it itself for a wiki in PostgreSQL.
#   2. toolchain/bootstrap.sh native --without-postgres --with-wizard
#      installs GHC and cabal (and on Debian the packages above, with root
#      or a sudo that needs no password), and checks again.
#   3. The toolchain's env file (~/.wiki-toolchain/env, or under
#      WIKI_TOOLCHAIN_HOME) puts them on PATH, and
#      `cabal run -z toolchain/configure.hs` runs the wizard from the
#      checkout's root. The first run compiles brick and vty, which takes a
#      few minutes; cabal keeps them for the runs after. -z keeps the script
#      out of the repository's cabal.project, which would otherwise make
#      cabal resolve every package of the wiki first.
#
# The deploy's output reaches the terminal, and its exit status is this
# script's. Relative paths given in the wizard are taken from the directory
# this was started in (WIKI_CONFIGURE_DIR tells the wizard which).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROG=configure

say() { printf '%s: %s\n' "$PROG" "$*"; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 1
}

case ${1:-} in
  -h | --help)
    sed -n '2,/^set -eu/{/^set -eu/d;s/^# \{0,1\}//;p;}' "$0"
    exit 0 ;;
esac

if ! check_output=$(sh "$ROOT/toolchain/check-native.sh" --without-postgres --with-wizard 2>&1); then
  printf '%s\n' "$check_output" >&2
  if command -v dpkg-query >/dev/null 2>&1; then
    warn "the bootstrap installs the Debian packages missing above next (as root, or through a sudo that needs no password)"
  else
    die "the wizard is compiled on this machine with GHC, and the machine lacks what is listed above: install it and run this again"
  fi
fi

sh "$ROOT/toolchain/bootstrap.sh" native --without-postgres --with-wizard ||
  die "the bootstrap could not install GHC and cabal (see above), which the wizard is compiled with"

env_file=${WIKI_TOOLCHAIN_HOME:-$HOME}/.wiki-toolchain/env
if [ -r "$env_file" ]; then
  # shellcheck source=/dev/null
  . "$env_file"
fi
command -v cabal >/dev/null 2>&1 ||
  die "cabal is not on PATH after the bootstrap: load $env_file (. $env_file) and run this again"

bin=$(cabal list-bin -z -v0 "$ROOT/toolchain/configure.hs" 2>/dev/null || true)
if [ -z "$bin" ] || [ ! -x "$bin" ]; then
  say "compiling the wizard: the first time, brick and vty as well, which takes a few minutes; cabal keeps them for the next runs"
fi

WIKI_CONFIGURE_DIR=$PWD
export WIKI_CONFIGURE_DIR
cd "$ROOT"
exec cabal run -z -v0 "$ROOT/toolchain/configure.hs" -- "$@"
