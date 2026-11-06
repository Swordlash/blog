#!/bin/sh
# Configure a deployment of the wiki in a terminal wizard, and run it: the
# wizard (maker-tui deploy) asks for toolchain/deploy-local.sh's options in
# a few screens, starting from the deployment's last run, shows the command
# line, and on Enter runs the deploy with it.
#
#   sh toolchain/configure.sh                   # the wizard
#   sh toolchain/configure.sh --args-from FILE  # print the command line FILE's answers make
#   sh toolchain/configure.sh --help
#
# For a machine that installs nothing from the internet, the deploy's
# options for it are taken here too, before --args-from or alone:
#
#   --system-tools         compile the wizard with this machine's own GHC and
#                          cabal, which the bootstrap checks and does not
#                          install (bootstrap.sh native --system-tools)
#   --hackage-mirror URL   take brick, vty and the cabal index from this
#                          Hackage mirror, written into the toolchain's own
#                          cabal configuration (bootstrap.sh native
#                          --hackage-mirror=URL), so WIKI_TOOLCHAIN_HOME must
#                          name a toolchain directory other than the home
#                          directory: the deployment's, such as
#                          /srv/wiki/toolchain for --prefix /srv/wiki
#   --npm-registry URL     the npm registry (NPM_CONFIG_REGISTRY); the wizard
#                          itself needs no npm
#
# Each is also given to the wizard, whose screens then start with it as the
# answer, so that the deploy it runs takes it too.
#
# The wizard is maker-tui's deploy command, a Haskell program with brick
# (maker/tui/Maker/Tui/Deploy.hs, its answers and command line in
# maker/src/Maker/Deploy/Wizard/), compiled on this machine with the
# maker's own cabal project, so this first gets what compiling it needs:
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
#      or a sudo that needs no password), and checks again; with
#      --system-tools and --hackage-mirror, as above.
#   3. The toolchain's env file (~/.wiki-toolchain/env, or under
#      WIKI_TOOLCHAIN_HOME) puts them on PATH, and
#      `sh toolchain/maker.sh tui deploy` builds maker-tui and runs the
#      wizard from the checkout's root, with this script's arguments. The
#      first run compiles brick and vty, which takes a few minutes; cabal
#      keeps them for the runs after.
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

# The options for a machine that installs nothing from the internet, for
# the bootstrap below; all the arguments go to the wizard as they are.
system_tools='' hackage_mirror='' npm_registry=''
expect_value=''
for arg do
  case $expect_value in
    --hackage-mirror) hackage_mirror=$arg expect_value=''; continue ;;
    --npm-registry) npm_registry=$arg expect_value=''; continue ;;
  esac
  case $arg in
    --system-tools) system_tools=--system-tools ;;
    --hackage-mirror | --npm-registry) expect_value=$arg ;;
    --hackage-mirror=*) hackage_mirror=${arg#*=} ;;
    --npm-registry=*) npm_registry=${arg#*=} ;;
  esac
done
[ -z "$expect_value" ] || die "$expect_value needs a URL"
if [ -n "$npm_registry" ]; then
  NPM_CONFIG_REGISTRY=$npm_registry
  export NPM_CONFIG_REGISTRY
fi

if ! check_output=$(sh "$ROOT/toolchain/check-native.sh" --without-postgres --with-wizard 2>&1); then
  printf '%s\n' "$check_output" >&2
  if command -v dpkg-query >/dev/null 2>&1; then
    warn "the bootstrap installs the Debian packages missing above next (as root, or through a sudo that needs no password)"
  else
    die "the wizard is compiled on this machine with GHC, and the machine lacks what is listed above: install it and run this again"
  fi
fi

sh "$ROOT/toolchain/bootstrap.sh" native --without-postgres --with-wizard ${system_tools:+"$system_tools"} ${hackage_mirror:+"--hackage-mirror=$hackage_mirror"} ||
  die "the bootstrap could not install GHC and cabal (see above), or did not take the options given, which the wizard is compiled with"

env_file=${WIKI_TOOLCHAIN_HOME:-$HOME}/.wiki-toolchain/env
if [ -r "$env_file" ]; then
  # shellcheck source=/dev/null
  . "$env_file"
fi
command -v cabal >/dev/null 2>&1 ||
  die "cabal is not on PATH after the bootstrap: load $env_file (. $env_file) and run this again"

bin=$(cd "$ROOT/maker" && cabal list-bin -v0 exe:maker-tui 2>/dev/null || true)
if [ -z "$bin" ] || [ ! -x "$bin" ]; then
  say "compiling the wizard: the first time, brick and vty as well, which takes a few minutes; cabal keeps them for the next runs"
fi

WIKI_CONFIGURE_DIR=$PWD
export WIKI_CONFIGURE_DIR
exec sh "$ROOT/toolchain/maker.sh" tui deploy "$@"
