#!/bin/sh
# Exercise discovery and install-mode reuse without touching the developer's
# home, network, package manager or real toolchain.
set -eu

SOURCE=$(cd "$(dirname "$0")" && pwd)/bootstrap.sh
SOURCE_DIR=${SOURCE%/*}
NODE_REAL=$(command -v node)
NPM_REAL=$(command -v npm)
export NODE_REAL
# Hosted setup may export its installation prefix. Discovery in these tests
# must use the temporary HOME rather than the runner's real ghcup.
unset GHCUP_INSTALL_BASE_PREFIX
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
REV=358ea50b8496a69da6ce375c0c58bc049dbcb92d
passed=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 lacks: $2"; }
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$*"; }
# The line number of the first line containing a string, for order checks.
line_of() { grep -n -F -- "$2" "$1" | head -n 1 | cut -d: -f1; }

fixture() {
  case_dir=$TMP/$1
  mkdir -p "$case_dir/home" "$case_dir/bin" "$case_dir/repo/toolchain"
  cp "$SOURCE" "$case_dir/repo/toolchain/bootstrap.sh"
  cp "$SOURCE_DIR/check-native.sh" "$SOURCE_DIR/check-tex.sh" "$case_dir/repo/toolchain/"
  HOME=$case_dir/home
  EVENTS=$case_dir/events
  CACHE=$case_dir/cache/chromium_headless_shell-1234
  CHROMIUM_NAME=chrome-headless-shell
  PATH=$case_dir/bin:/usr/bin:/bin
  NODE_REPORT=v24.99.0 GHC_REPORT=9.14.1
  export HOME EVENTS CACHE CHROMIUM_NAME PATH NODE_REPORT GHC_REPORT
  : >"$EVENTS"
  mkdir -p "$HOME/index/hackage.haskell.org"
  touch "$HOME/index/hackage.haskell.org/01-index.tar"
  cat >"$case_dir/bin/tool" <<'EOF'
#!/bin/sh
name=${0##*/}
case $name in
  ghc) printf '%s\n' "$GHC_REPORT" ;;
  wasm32-wasi-ghc) printf '9.14.1.20260731\n' ;;
  cabal)
    case $1 in
      --numeric-version) printf '%s\n' "${CABAL_REPORT:-3.16.1.0}" ;;
      path) printf '%s/index\n' "$HOME" ;;
      user-config)
        # As cabal user-config init writes its default configuration.
        printf 'cabal %s CABAL_DIR=%s\n' "$*" "${CABAL_DIR:-}" >>"$EVENTS"
        mkdir -p "$CABAL_DIR"
        printf -- '-- This is the configuration file for the cabal command line tool.\nrepository hackage.haskell.org\n  url: http://hackage.haskell.org/\n  -- secure: True\n  -- root-keys:\n\n-- ignore-expiry: False\njobs: $ncpus\n' >"$CABAL_DIR/config" ;;
      build | test) printf 'cabal'; printf ' <%s>' "$@"; printf '\n' ;;
      update)
        printf 'cabal %s\n' "$*" >>"$EVENTS"
        printf 'Downloading the package index (the fake cabal)\n'
        [ -z "${FAKE_CABAL_FAIL:-}" ] || exit 1
        touch "$HOME/index/hackage.haskell.org/01-index.tar" ;;
      *) printf 'unexpected cabal %s\n' "$*" >>"$EVENTS"; exit 91 ;;
    esac ;;
  node)
    if [ "${1:-}" = --version ]; then printf '%s\n' "$NODE_REPORT"; else exec "$NODE_REAL" "$@"; fi ;;
  npm)
    [ "${1:-}" != --version ] || { printf '11.0.0\n'; exit 0; }
    printf 'unexpected npm %s\n' "$*" >>"$EVENTS"; exit 91 ;;
  fourmolu) printf 'fourmolu 0.21.0.0\n' ;;
  dpkg-query) printf 'install ok installed\n' ;;
  curl|apt-get|sudo) printf 'unexpected %s %s\n' "$name" "$*" >>"$EVENTS"; exit 91 ;;
  git)
    # The GitHub mirror of ghc-wasm-meta: a checkout of the pinned commit
    # holds ghcup's metadata and a setup.sh that writes a sysroot like
    # sysroot() does, saying how it was called.
    printf 'git %s\n' "$*" >>"$EVENTS"
    dir=
    [ "$1" != -C ] || dir=$2
    case $* in
      'init -q '*) mkdir -p "$3/.git" ;;
      *' fetch -q --depth 1 https://github.com/haskell-wasm/ghc-wasm-meta '*) ;;
      *' checkout -q FETCH_HEAD')
        printf 'ghcupURL: fake\n' >"$dir/ghcup-wasm-0.0.9.yaml"
        cp "$FAKE_SETUP" "$dir/setup.sh" ;;
      *) printf 'unexpected git %s\n' "$*" >>"$EVENTS"; exit 91 ;;
    esac ;;
  *) exit 91 ;;
esac
EOF
  chmod +x "$case_dir/bin/tool"
  for cmd in ghc cabal wasm32-wasi-ghc node npm fourmolu dpkg-query curl apt-get sudo git; do
    ln -s tool "$case_dir/bin/$cmd"
  done
  # An xelatex that typesets toolchain/check-tex.sh's probe at once, ahead
  # of the host's own on PATH: toolchain/check-native.sh tries the one it
  # finds, and the host's would take seconds, or fail, at every check.
  fake_xelatex working
  FAKE_SETUP=$case_dir/fake-setup.sh
  export FAKE_SETUP
  cat >"$FAKE_SETUP" <<'EOF'
#!/bin/sh
printf 'setup.sh PREFIX=%s SKIP_GHC=%s FLAVOUR=%s\n' "$PREFIX" "$SKIP_GHC" "$FLAVOUR" >>"$EVENTS"
rm -rf "$PREFIX"
mkdir -p "$PREFIX/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi"
touch "$PREFIX/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/libc.a" "$PREFIX/env"
for binary in add_to_github_path.sh wasi-sdk/bin/wasm32-wasi-clang binaryen/bin/wasm-opt wasmtime/bin/wasmtime nodejs/bin/node; do
  mkdir -p "$(dirname "$PREFIX/$binary")"
  printf '#!/bin/sh\nexit 0\n' >"$PREFIX/$binary"
  chmod +x "$PREFIX/$binary"
done
EOF
  mkdir -p "$case_dir/repo/node_modules/playwright-core"
  printf '{"packages":{"node_modules/playwright-core":{"version":"1.63.0"}}}\n' >"$case_dir/repo/package-lock.json"
  printf '{"version":"1.63.0","main":"index.cjs"}\n' >"$case_dir/repo/node_modules/playwright-core/package.json"
  cat >"$case_dir/repo/node_modules/playwright-core/cli.js" <<'EOF'
const fs = require('fs');
const path = require('path');
if (process.argv.includes('--dry-run')) {
  console.log('  Install location: ' + process.env.CACHE);
} else if (process.argv[2] === 'install') {
  fs.appendFileSync(process.env.EVENTS, 'chromium install\n');
  const exe = path.join(process.env.CACHE, 'chrome-headless-shell-linux64', process.env.CHROMIUM_NAME);
  fs.mkdirSync(path.dirname(exe), {recursive: true});
  fs.writeFileSync(exe, '#!/bin/sh\nexit 0\n', {mode: 0o755});
  fs.writeFileSync(path.join(process.env.CACHE, 'INSTALLATION_COMPLETE'), '');
} else { process.exit(91); }
EOF
  cat >"$case_dir/repo/node_modules/playwright-core/index.cjs" <<'EOF'
const fs = require('fs');
exports.chromium = {launch: async () => {
  fs.appendFileSync(process.env.EVENTS, 'chromium launch\n');
  return {close: async () => {}};
}};
EOF
  mkdir -p "$case_dir/repo/node_modules/playwright-core/lib"
  cat >"$case_dir/repo/node_modules/playwright-core/lib/coreBundle.js" <<'EOF'
const path = require('node:path');
exports.registry = {registry: {findExecutable: (name) => {
  if (name !== 'chromium-headless-shell') throw new Error('unexpected browser');
  return {
    directory: process.env.CACHE,
    executablePath: () => path.join(process.env.CACHE, 'chrome-headless-shell-linux64', process.env.CHROMIUM_NAME),
  };
}}};
EOF
  mkdir -p "$CACHE/chrome-headless-shell-linux64"
  printf '#!/bin/sh\nexit 0\n' >"$CACHE/chrome-headless-shell-linux64/$CHROMIUM_NAME"
  chmod +x "$CACHE/chrome-headless-shell-linux64/$CHROMIUM_NAME"
  touch "$CACHE/INSTALLATION_COMPLETE"
}

# Write the fixture's xelatex: one that makes check-tex.sh's probe.pdf
# (working), or one that stops as TeX Live 2020 does under kpathsea's
# paranoid mode (failing).
fake_xelatex() {
  case $1 in
    working)
      printf '#!/bin/sh\nprintf "%%%%PDF fake\\n" >probe.pdf\n' >"$case_dir/bin/xelatex" ;;
    failing)
      printf '#!/bin/sh\nprintf "! I can'"'"'t find file unicode-math-table.tex.\\n" >probe.log\nexit 1\n' >"$case_dir/bin/xelatex" ;;
  esac
  chmod +x "$case_dir/bin/xelatex"
}

sysroot() {
  prefix=${1:-$HOME}/.ghc-wasm
  mkdir -p "$prefix/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi"
  touch "$prefix/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/libc.a" "$prefix/env"
  printf '%s\n' "$REV" >"$prefix/.paladyn-rev"
  for binary in add_to_github_path.sh wasi-sdk/bin/wasm32-wasi-clang binaryen/bin/wasm-opt wasmtime/bin/wasmtime nodejs/bin/node; do
    mkdir -p "$(dirname "$prefix/$binary")"
    printf '#!/bin/sh\nexit 0\n' >"$prefix/$binary"
    chmod +x "$prefix/$binary"
  done
}

bootstrap() { sh "$case_dir/repo/toolchain/bootstrap.sh" "$@"; }
snapshot() {
  # Include names, contents, permissions and mtimes, so check cannot quietly
  # create a log, rewrite an env file or mark somebody else's sysroot as ours.
  find "$HOME" "$case_dir/repo" "$case_dir/bin" "$case_dir/cache" -printf '%p %m %T@ %l\n' | sort
  find "$HOME" "$case_dir/repo" "$case_dir/bin" "$case_dir/cache" -type f -exec sha256sum {} + | sort
}

fixture reuse
sysroot
snapshot >"$case_dir/before"
bootstrap check >"$case_dir/check"
snapshot >"$case_dir/after"
cmp "$case_dir/before" "$case_dir/after" || fail 'check mutated fixtures'
assert_contains "$case_dir/check" 'reuse ghc 9.14.1'
assert_contains "$case_dir/check" 'reuse wasm sysroot'
assert_contains "$case_dir/check" 'reuse Node v24.99.0'
assert_contains "$case_dir/check" "reuse playwright-core 1.63.0 ($case_dir/repo)"
assert_contains "$case_dir/check" 'reuse Chromium cache'
[ ! -s "$EVENTS" ] || fail 'check ran a mutation command'
pass 'check is read-only and recognises pinned PATH tools and project Playwright'

bootstrap toolchain >"$case_dir/first"
bootstrap toolchain >"$case_dir/second"
[ "$(cat "$EVENTS")" = "$(printf 'chromium launch\nchromium launch')" ] || fail 'reuse downloaded or installed tools'
[ ! -e "$HOME/.wiki-toolchain/node" ] || fail 'reuse installed duplicate Node'
[ ! -e "$HOME/.ghcup" ] || fail 'reuse unnecessarily installed ghcup'
[ ! -e "$HOME/.wiki-toolchain/ghc-wasm-meta-$REV" ] || fail 'reuse fetched wasm metadata'
[ ! -e "$HOME/.ghc-wasm/.bootstrap-$REV" ] || fail 'reuse stamped an external sysroot'
pass 'install-mode runs reuse external tools twice without downloads or ghcup'

# A stale marker must not suppress repair or a fresh launch check.
touch "$CACHE/.bootstrap-launched"
rm "$CACHE/chrome-headless-shell-linux64/$CHROMIUM_NAME"
: >"$EVENTS"
bootstrap toolchain >"$case_dir/repair"
[ "$(cat "$EVENTS")" = "$(printf 'chromium install\nchromium launch')" ] || fail 'broken Chromium cache was not repaired'
pass 'a stale browser marker does not hide a missing executable'

# A Debian machine without libpq-dev (or the package given), and without
# root or a sudo that needs no password: dpkg-query reports every package
# installed but that one, id -u is not 0, and sudo -n fails.
# no_debian_fakes puts the fixture's tools back.
debian_without_libpq() {
  # The fixture's dpkg-query and sudo are links to its tool: they are
  # removed first, so that writing the fakes does not write through them.
  rm -f "$case_dir/bin/dpkg-query" "$case_dir/bin/id" "$case_dir/bin/sudo"
  cat >"$case_dir/bin/dpkg-query" <<EOF
#!/bin/sh
[ "\$4" != ${1:-libpq-dev} ] || exit 1
printf 'install ok installed\\n'
EOF
  cat >"$case_dir/bin/id" <<'EOF'
#!/bin/sh
if [ "$1" = -u ]; then printf '1000\n'; else exec /usr/bin/id "$@"; fi
EOF
  cat >"$case_dir/bin/sudo" <<'EOF'
#!/bin/sh
[ "$*" = '-n true' ] && exit 1
printf 'unexpected sudo %s\n' "$*" >>"$EVENTS"
exit 91
EOF
  chmod +x "$case_dir/bin/dpkg-query" "$case_dir/bin/id" "$case_dir/bin/sudo"
}
no_debian_fakes() {
  rm -f "$case_dir/bin/dpkg-query" "$case_dir/bin/id" "$case_dir/bin/sudo"
  ln -s tool "$case_dir/bin/dpkg-query"
  ln -s tool "$case_dir/bin/sudo"
}

# The Dockerfile's builder installs what a build needs and nothing more: with
# no fourmolu on PATH and no Chromium in the cache, `build` installs neither
# (here any attempt would reach curl or Playwright and be recorded).
fixture build-only
sysroot
rm "$case_dir/bin/fourmolu" "$CACHE/chrome-headless-shell-linux64/$CHROMIUM_NAME" "$CACHE/INSTALLATION_COMPLETE"
bootstrap build >"$case_dir/build"
[ ! -s "$EVENTS" ] || fail "build installed or launched something: $(cat "$EVENTS")"
assert_contains "$case_dir/build" 'no Chromium or fourmolu (build)'
[ -f "$HOME/.wiki-toolchain/env" ] || fail 'build did not write the environment file'
# On Debian without libpq-dev and without root, plain build stops at the
# Debian packages, naming libpq-dev; build --without-postgres (the deploy's,
# for a wiki in SQLite) does not ask for it and installs nothing. Another
# option is refused.
debian_without_libpq
status=0
bootstrap build >"$case_dir/build-debian-no-libpq" 2>&1 || status=$?
[ "$status" = 1 ] || fail "build on Debian without libpq-dev or root exited $status, not 1"
assert_contains "$case_dir/build-debian-no-libpq" 'missing Debian packages: libpq-dev; install them (sudo apt-get install libpq-dev)'
bootstrap build --without-postgres >"$case_dir/build-without-postgres" 2>&1 ||
  fail "build --without-postgres on Debian without libpq-dev failed: $(cat "$case_dir/build-without-postgres")"
if grep -F 'missing Debian packages' "$case_dir/build-without-postgres" >/dev/null; then fail 'build --without-postgres asked Debian for libpq-dev'; fi
assert_contains "$case_dir/build-without-postgres" 'no Chromium or fourmolu (build)'
status=0
bootstrap build --postgres >"$case_dir/build-bad-option" 2>&1 || status=$?
[ "$status" = 2 ] || fail "build with an unknown option exited $status, not 2"
assert_contains "$case_dir/build-bad-option" 'build [--without-postgres]'
[ ! -s "$EVENTS" ] || fail "build on Debian without libpq-dev installed something: $(cat "$EVENTS")"
no_debian_fakes
pass 'build installs the compilers and Node, and neither Chromium nor fourmolu; with --without-postgres it does not ask Debian for libpq-dev'

# What toolchain/deploy-local.sh --backend-only needs: GHC and cabal alone.
# With no Node, no sysroot, no fourmolu and no Chromium,
# `native` installs none of them (any attempt would reach the fake curl, git,
# npm, cabal install or Playwright and be recorded), leaves a ~/.ghc-wasm it
# does not recognise alone, and writes the environment file. Then, on
# Debian or not, it runs toolchain/check-native.sh. What that script checks
# is faked, so that the result does not depend on the host: cc preprocesses
# anything and links the libsodium probe unless SODIUM_MISSING is set (and
# the terminfo probe unless TINFO_MISSING is),
# pkg-config knows zlib and libpq, and make and pg_config answer.
fixture native
rm "$case_dir/bin/node" "$case_dir/bin/npm" "$case_dir/bin/fourmolu" \
  "$CACHE/chrome-headless-shell-linux64/$CHROMIUM_NAME" "$CACHE/INSTALLATION_COMPLETE"
cat >"$case_dir/bin/cc" <<'EOF'
#!/bin/sh
output= sodium= tinfo=
while [ $# -gt 0 ]; do
  case $1 in
    -o) output=$2; shift ;;
    -lsodium) sodium=1 ;;
    -ltinfo) tinfo=1 ;;
  esac
  shift
done
if [ -z "$output" ]; then cat >/dev/null; exit 0; fi
if [ -n "$sodium" ] && [ -n "${SODIUM_MISSING:-}" ]; then
  printf 'cannot find -lsodium\n' >&2
  exit 1
fi
if [ -n "$tinfo" ] && [ -n "${TINFO_MISSING:-}" ]; then
  printf 'cannot find -ltinfo\n' >&2
  exit 1
fi
printf '#!/bin/sh\n' >"$output"
chmod +x "$output"
EOF
printf '#!/bin/sh\ncase $* in "--exists zlib" | "--exists libpq") exit 0 ;; esac\nexit 1\n' >"$case_dir/bin/pkg-config"
printf '#!/bin/sh\nprintf "/usr/lib/postgresql/17/bin\\n"\n' >"$case_dir/bin/pg_config"
printf '#!/bin/sh\nexit 0\n' >"$case_dir/bin/make"
chmod +x "$case_dir/bin/cc" "$case_dir/bin/pkg-config" "$case_dir/bin/pg_config" "$case_dir/bin/make"
mkdir -p "$HOME/.ghc-wasm"
printf 'keep me\n' >"$HOME/.ghc-wasm/custom"
bootstrap native >"$case_dir/native"
[ ! -s "$EVENTS" ] || fail "native installed or launched something: $(cat "$EVENTS")"
assert_contains "$case_dir/native" 'no wasm toolchain, Node, Chromium or fourmolu (native)'
[ -f "$HOME/.wiki-toolchain/env" ] || fail 'native did not write the environment file'
[ "$(ls -A "$HOME/.ghc-wasm")" = custom ] || fail 'native touched ~/.ghc-wasm'
[ ! -e "$HOME/.wiki-toolchain/node" ] || fail 'native installed Node'
# The Debian packages are all installed (the fake dpkg-query says so), but
# the check still finds a library that does not link, and stops the run.
if SODIUM_MISSING=1 bootstrap native >"$case_dir/native-no-sodium" 2>&1; then fail 'native without libsodium succeeded'; fi
assert_contains "$case_dir/native-no-sodium" 'missing  libsodium'
assert_contains "$case_dir/native-no-sodium" 'Debian, Ubuntu: sudo apt-get install libsodium-dev'
assert_contains "$case_dir/native-no-sodium" 'the native build of wiki-server needs what is missing above'
# The machine without dpkg-query. Removing the fake one is not enough: on a
# Debian host the PATH would still reach the host's /usr/bin/dpkg-query,
# which reports the host's own packages (GitHub's runner has no
# build-essential). So these runs get a PATH of the fake tools and a
# directory of links to the commands in /usr/bin and /bin, without
# dpkg-query, cc and make. env sets that PATH for the one command, so sh is
# found among the links. Of the commands the check looks up (cc, make, curl,
# git and pkg-config), all are fakes, so the result does not depend on what
# the host has installed.
rm "$case_dir/bin/dpkg-query"
no_dpkg=$case_dir/no-dpkg
mkdir "$no_dpkg"
for cmd in /usr/bin/* /bin/*; do
  name=${cmd##*/}
  case $name in dpkg-query | cc | make | xelatex) continue ;; esac
  if [ ! -f "$cmd" ] || [ ! -x "$cmd" ]; then continue; fi
  [ -e "$no_dpkg/$name" ] || [ -L "$no_dpkg/$name" ] || ln -s "$cmd" "$no_dpkg/$name"
done
env PATH="$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native >"$case_dir/native-rhel" 2>&1 ||
  fail "native without dpkg-query failed: $(cat "$case_dir/native-rhel")"
[ ! -s "$EVENTS" ] || fail "native without dpkg-query installed something: $(cat "$EVENTS")"
if grep -F 'Debian packages' "$case_dir/native-rhel" >/dev/null; then fail 'native without dpkg-query checked Debian packages'; fi
# The check is silent when everything is there, so take the fake make away
# too: the check names it, with its packages.
rm "$case_dir/bin/make"
if env PATH="$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native >"$case_dir/native-rhel-no-make" 2>&1; then
  fail 'native without dpkg-query or make succeeded'
fi
assert_contains "$case_dir/native-rhel-no-make" 'missing  make'
assert_contains "$case_dir/native-rhel-no-make" 'RHEL, Fedora:   sudo dnf install make'
[ ! -s "$EVENTS" ] || fail "native without make installed something: $(cat "$EVENTS")"
# pkg-config knows libpq, but pg_config is not on PATH, as on RHEL with
# PGDG's packages: the build runs pg_config, so the check names libpq and
# says to put pg_config's directory on PATH, naming the one it finds off
# PATH. WIKI_PG_CONFIG_DIRS stands for /usr/pgsql-*/bin and
# /usr/lib/postgresql/*/bin, and the host's own pg_config is taken out of
# the links.
printf '#!/bin/sh\nexit 0\n' >"$case_dir/bin/make"
chmod +x "$case_dir/bin/make"
rm -f "$case_dir/bin/pg_config" "$no_dpkg/pg_config"
if WIKI_PG_CONFIG_DIRS=$case_dir/nowhere env PATH="$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native >"$case_dir/native-no-pg-config" 2>&1; then
  fail 'native without pg_config on PATH succeeded'
fi
assert_contains "$case_dir/native-no-pg-config" 'missing  libpq       no pg_config on PATH, though pkg-config knows libpq: the build runs pg_config'
assert_contains "$case_dir/native-no-pg-config" "PATH=/usr/pgsql-NN/bin:\$PATH sh toolchain/deploy-local.sh"
mkdir -p "$case_dir/pgsql-16/bin"
printf '#!/bin/sh\nprintf "/usr/pgsql-16/include\\n"\n' >"$case_dir/pgsql-16/bin/pg_config"
chmod +x "$case_dir/pgsql-16/bin/pg_config"
if WIKI_PG_CONFIG_DIRS="$case_dir/pgsql-*/bin" env PATH="$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native >"$case_dir/native-pg-config-elsewhere" 2>&1; then
  fail 'native with pg_config off PATH succeeded'
fi
assert_contains "$case_dir/native-pg-config-elsewhere" "no pg_config on PATH, but there is one at $case_dir/pgsql-16/bin/pg_config"
assert_contains "$case_dir/native-pg-config-elsewhere" "PATH=$case_dir/pgsql-16/bin:\$PATH sh toolchain/deploy-local.sh"
# For a wiki-server built without PostgreSQL (deploy-local.sh --sqlite),
# native --without-postgres passes the option to the check, which then does
# not ask for libpq: the same machine passes. Another option is refused.
WIKI_PG_CONFIG_DIRS=$case_dir/nowhere env PATH="$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native --without-postgres >"$case_dir/native-without-postgres" 2>&1 ||
  fail "native --without-postgres without pg_config failed: $(cat "$case_dir/native-without-postgres")"
if grep -F libpq "$case_dir/native-without-postgres" >/dev/null; then fail 'native --without-postgres reported libpq'; fi
assert_contains "$case_dir/native-without-postgres" 'no wasm toolchain, Node, Chromium or fourmolu (native)'
status=0
env PATH="$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native --postgres >"$case_dir/native-bad-option" 2>&1 || status=$?
[ "$status" = 2 ] || fail "native with an unknown option exited $status, not 2"
assert_contains "$case_dir/native-bad-option" 'native [--without-postgres]'
# Debian without libpq-dev, and without root or a sudo that needs no
# password: plain native stops at the Debian packages, naming libpq-dev;
# native --without-postgres does not ask for it, installs nothing, and goes
# on to the check (which a missing libsodium then stops, to show that it ran).
debian_without_libpq
status=0
WIKI_PG_CONFIG_DIRS=$case_dir/nowhere env PATH="$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native >"$case_dir/native-debian-no-libpq" 2>&1 || status=$?
[ "$status" = 1 ] || fail "native on Debian without libpq-dev or root exited $status, not 1"
assert_contains "$case_dir/native-debian-no-libpq" 'missing Debian packages: libpq-dev; install them (sudo apt-get install libpq-dev)'
WIKI_PG_CONFIG_DIRS=$case_dir/nowhere env PATH="$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native --without-postgres >"$case_dir/native-debian-without-postgres" 2>&1 ||
  fail "native --without-postgres on Debian without libpq-dev failed: $(cat "$case_dir/native-debian-without-postgres")"
if grep -F 'missing Debian packages' "$case_dir/native-debian-without-postgres" >/dev/null; then fail 'native --without-postgres asked Debian for libpq-dev'; fi
assert_contains "$case_dir/native-debian-without-postgres" 'no wasm toolchain, Node, Chromium or fourmolu (native)'
status=0
SODIUM_MISSING=1 WIKI_PG_CONFIG_DIRS=$case_dir/nowhere env PATH="$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native --without-postgres >"$case_dir/native-debian-check" 2>&1 || status=$?
[ "$status" = 1 ] || fail "native --without-postgres without libsodium exited $status, not 1"
assert_contains "$case_dir/native-debian-check" 'missing  libsodium'
assert_contains "$case_dir/native-debian-check" 'skipped  libpq       not needed (built without PostgreSQL)'
[ ! -s "$EVENTS" ] || fail "native on Debian without libpq-dev installed something: $(cat "$EVENTS")"
no_debian_fakes
rm "$case_dir/bin/dpkg-query"
env PATH="$case_dir/pgsql-16/bin:$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native >"$case_dir/native-pg-config-on-path" 2>&1 ||
  fail "native with that pg_config on PATH failed: $(cat "$case_dir/native-pg-config-on-path")"
[ ! -s "$EVENTS" ] || fail "native without pg_config installed something: $(cat "$EVENTS")"
pass 'native installs GHC and cabal alone, with no wasm toolchain, Node, Chromium or fourmolu, on Debian or not, and checks what the native build needs after the Debian packages, libpq through pg_config on PATH, or, with --without-postgres, neither libpq-dev from Debian nor libpq in the check'

# The configuration wizard (toolchain/configure.sh) runs native
# --without-postgres --with-wizard. On Debian without libncurses-dev and
# without root, that stops at the Debian packages, naming it; native
# without --with-wizard does not ask for it. The check then reports
# terminfo, which plain native skips; without -ltinfo the check stops the
# run. build takes no --with-wizard.
debian_without_libpq libncurses-dev
status=0
env PATH="$case_dir/pgsql-16/bin:$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native --without-postgres --with-wizard >"$case_dir/native-wizard-no-ncurses" 2>&1 || status=$?
[ "$status" = 1 ] || fail "native --with-wizard on Debian without libncurses-dev or root exited $status, not 1"
assert_contains "$case_dir/native-wizard-no-ncurses" 'missing Debian packages: libncurses-dev; install them (sudo apt-get install libncurses-dev)'
env PATH="$case_dir/pgsql-16/bin:$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native --without-postgres >"$case_dir/native-no-wizard" 2>&1 ||
  fail "native without --with-wizard on Debian without libncurses-dev failed: $(cat "$case_dir/native-no-wizard")"
if grep -F 'libncurses-dev' "$case_dir/native-no-wizard" >/dev/null; then fail 'native without --with-wizard asked Debian for libncurses-dev'; fi
no_debian_fakes
env PATH="$case_dir/pgsql-16/bin:$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native --with-wizard --without-postgres >"$case_dir/native-wizard" 2>&1 ||
  fail "native --with-wizard failed: $(cat "$case_dir/native-wizard")"
assert_contains "$case_dir/native-wizard" 'no wasm toolchain, Node, Chromium or fourmolu (native)'
status=0
TINFO_MISSING=1 env PATH="$case_dir/pgsql-16/bin:$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native --without-postgres --with-wizard >"$case_dir/native-wizard-no-tinfo" 2>&1 || status=$?
[ "$status" = 1 ] || fail "native --with-wizard without -ltinfo exited $status, not 1"
assert_contains "$case_dir/native-wizard-no-tinfo" 'missing  terminfo'
assert_contains "$case_dir/native-wizard-no-tinfo" 'sudo apt-get install libncurses-dev'
assert_contains "$case_dir/native-wizard-no-tinfo" 'sudo dnf install ncurses-devel'
TINFO_MISSING=1 env PATH="$case_dir/pgsql-16/bin:$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" native --without-postgres >"$case_dir/native-no-tinfo" 2>&1 ||
  fail "native without --with-wizard and without -ltinfo failed: $(cat "$case_dir/native-no-tinfo")"
status=0
env PATH="$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/bootstrap.sh" build --with-wizard >"$case_dir/build-wizard" 2>&1 || status=$?
[ "$status" = 2 ] || fail "build --with-wizard exited $status, not 2"
assert_contains "$case_dir/build-wizard" 'build [--without-postgres]'
[ ! -s "$EVENTS" ] || fail "native --with-wizard installed something: $(cat "$EVENTS")"
pass 'native --with-wizard asks Debian for libncurses-dev and checks terminfo; native alone does neither'

# toolchain/check-native.sh by itself: terminfo is skipped and not counted
# without --with-wizard, and checked and counted with it.
out=$case_dir/check-plain
env PATH="$case_dir/pgsql-16/bin:$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/check-native.sh" >"$out" 2>&1 || fail "the check failed: $(cat "$out")"
assert_contains "$out" 'skipped  terminfo    not needed (for the configuration wizard only: --with-wizard)'
assert_contains "$out" 'All 9 items the native build of wiki-server needs are there.'
out=$case_dir/check-wizard
env PATH="$case_dir/pgsql-16/bin:$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/check-native.sh" --with-wizard >"$out" 2>&1 || fail "the check --with-wizard failed: $(cat "$out")"
assert_contains "$out" 'ok       terminfo    -ltinfo, through cc (for the configuration wizard)'
assert_contains "$out" 'All 10 items the native build of wiki-server and the configuration wizard need are there.'
out=$case_dir/check-wizard-no-tinfo
status=0
TINFO_MISSING=1 env PATH="$case_dir/pgsql-16/bin:$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/check-native.sh" --without-postgres --with-wizard >"$out" 2>&1 || status=$?
[ "$status" = 1 ] || fail "the check --with-wizard without -ltinfo exited $status, not 1"
assert_contains "$out" 'missing  terminfo    cc cannot link a program with -ltinfo (the configuration wizard needs it) (Debian: libncurses-dev; RHEL: ncurses-devel)'
assert_contains "$out" 'Missing for the native build of wiki-server and the configuration wizard: terminfo.'
pass 'toolchain/check-native.sh checks terminfo with --with-wizard only'

# The xelatex of the PDF exports, through toolchain/check-tex.sh: a line
# of its own after the commands, ok when the fake typesets the probe, no
# with the reason's first line when it fails, no when PATH has none (the
# links leave the host's out). It is never counted and never makes the
# check fail, and the summary says what the PDF exports need, also after
# a missing item.
out=$case_dir/check-tex-working
env PATH="$case_dir/pgsql-16/bin:$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/check-native.sh" >"$out" 2>&1 || fail "the check with a working xelatex failed: $(cat "$out")"
assert_contains "$out" "ok       xelatex     working at $case_dir/bin/xelatex (for the PDF exports; not counted)"
assert_contains "$out" 'All 9 items the native build of wiki-server needs are there.'
if grep -F 'PDF exports need' "$out" >/dev/null; then fail 'the check with a working xelatex spoke of the PDF exports'; fi
if [ "$(line_of "$out" 'pkg-config')" -gt "$(line_of "$out" 'xelatex')" ] || [ "$(line_of "$out" 'xelatex')" -gt "$(line_of "$out" 'GMP')" ]; then
  fail 'the xelatex line is not after the commands'
fi
fake_xelatex failing
out=$case_dir/check-tex-failing
env PATH="$case_dir/pgsql-16/bin:$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/check-native.sh" >"$out" 2>&1 || fail "the check with a failing xelatex failed: $(cat "$out")"
assert_contains "$out" "no       xelatex     failing at $case_dir/bin/xelatex: It exited 1. (for the PDF exports; not counted)"
assert_contains "$out" 'All 9 items the native build of wiki-server needs are there.'
assert_contains "$out" "PDF exports need xelatex: $case_dir/bin/xelatex fails (sh toolchain/check-tex.sh says why), so the server would offer no PDFs (the deploy offers TeX Live under the toolchain: sh toolchain/deploy-local.sh --server --texlive)."
rm "$case_dir/bin/xelatex"
out=$case_dir/check-tex-none
status=0
TINFO_MISSING=1 env PATH="$case_dir/pgsql-16/bin:$case_dir/bin:$no_dpkg" sh "$case_dir/repo/toolchain/check-native.sh" --with-wizard >"$out" 2>&1 || status=$?
[ "$status" = 1 ] || fail "the check without -ltinfo and xelatex exited $status, not 1"
assert_contains "$out" 'no       xelatex     not-found: no xelatex on PATH (for the PDF exports; not counted)'
assert_contains "$out" 'Missing for the native build of wiki-server and the configuration wizard: terminfo.'
if grep -F 'Missing for the native build of wiki-server and the configuration wizard: terminfo, xelatex' "$out" >/dev/null; then fail 'xelatex was counted as missing'; fi
assert_contains "$out" 'PDF exports need xelatex: none is on PATH, so the server would offer no PDFs'
fake_xelatex working
pass 'toolchain/check-native.sh says whether xelatex typesets the PDF exports, and never fails for it'

# What toolchain/deploy-local.sh --static --backend-only needs: Node alone.
# With no GHC, cabal, wasm compiler or fourmolu on PATH, `node`
# installs none of them (any attempt would reach the fake curl, git or
# cabal install and be recorded), reuses the Node 24 on PATH, leaves a
# ~/.ghc-wasm it does not recognise alone, and writes the environment file.
# With only an older Node on PATH it downloads Node, and nothing else.
fixture node
rm "$case_dir/bin/ghc" "$case_dir/bin/cabal" "$case_dir/bin/wasm32-wasi-ghc" "$case_dir/bin/fourmolu"
mkdir -p "$HOME/.ghc-wasm"
printf 'keep me\n' >"$HOME/.ghc-wasm/custom"
bootstrap node >"$case_dir/node"
[ ! -s "$EVENTS" ] || fail "node installed or launched something: $(cat "$EVENTS")"
assert_contains "$case_dir/node" 'Node v24.99.0; no compilers, wasm toolchain, Chromium or fourmolu (node)'
[ -f "$HOME/.wiki-toolchain/env" ] || fail 'node did not write the environment file'
[ "$(ls -A "$HOME/.ghc-wasm")" = custom ] || fail 'node touched ~/.ghc-wasm'
[ ! -e "$HOME/.ghcup" ] || fail 'node installed ghcup'
[ ! -e "$HOME/.wiki-toolchain/node" ] || fail 'node installed Node over a compatible one'
NODE_REPORT=v22.0.0
export NODE_REPORT
if bootstrap node >"$case_dir/node-old" 2>&1; then fail 'node succeeded without downloading Node'; fi
assert_contains "$case_dir/node-old" 'downloading Node failed'
[ "$(cat "$EVENTS")" = "unexpected curl --fail --location --retry 5 --silent --show-error --output $HOME/.wiki-toolchain/node-v24.21.0-linux-x64.tar.xz https://nodejs.org/dist/v24.21.0/node-v24.21.0-linux-x64.tar.xz" ] ||
  fail "node with an old Node did more than download Node: $(cat "$EVENTS")"
[ "$(ls -A "$HOME/.ghc-wasm")" = custom ] || fail 'node touched ~/.ghc-wasm'
pass 'node installs Node alone, reusing a Node 24 on PATH, with no compilers, wasm toolchain, Chromium or fourmolu'

# A long step in toolchain mode, which the SessionStart hooks use: here cabal
# updating a missing package index. Its output is kept in the log alone, and
# the next run, with the index there, does not update it again.
fixture index
sysroot
rm "$HOME/index/hackage.haskell.org/01-index.tar"
bootstrap toolchain >"$case_dir/install"
assert_contains "$EVENTS" 'cabal update'
if grep -F '(the fake cabal)' "$case_dir/install" >/dev/null; then fail 'toolchain mode showed a long step'"'"'s output'; fi
assert_contains "$HOME/.wiki-toolchain/bootstrap.log" 'Downloading the package index (the fake cabal)'
: >"$EVENTS"
bootstrap toolchain >"$case_dir/repeat"
[ "$(cat "$EVENTS")" = 'chromium launch' ] || fail 'the package index was updated again'
pass "in toolchain mode a long step's output is logged alone, and an index that is there is not updated"

# In the modes toolchain/deploy-local.sh uses, a long step's output is shown
# as it comes and kept in the log (above, in toolchain mode, it is logged
# alone): here cabal updating the package index in build mode. A long step
# that fails still stops the run, naming the step.
fixture index-build
sysroot
rm "$case_dir/bin/fourmolu" "$CACHE/chrome-headless-shell-linux64/$CHROMIUM_NAME" "$CACHE/INSTALLATION_COMPLETE"
rm "$HOME/index/hackage.haskell.org/01-index.tar"
if FAKE_CABAL_FAIL=1 bootstrap build >"$case_dir/build-fails" 2>&1; then fail 'build with a failing cabal update succeeded'; fi
assert_contains "$case_dir/build-fails" 'Downloading the package index (the fake cabal)'
assert_contains "$case_dir/build-fails" "bootstrap: updating cabal's package index failed"
bootstrap build >"$case_dir/build"
assert_contains "$case_dir/build" 'Downloading the package index (the fake cabal)'
assert_contains "$HOME/.wiki-toolchain/bootstrap.log" 'Downloading the package index (the fake cabal)'
assert_contains "$EVENTS" 'cabal update'
pass "in build and native modes a long step's output is shown as well as logged, and a failing one stops the run"

for kind in unknown incomplete wrong-revision; do
  fixture "$kind"
  if [ "$kind" = unknown ]; then
    mkdir -p "$HOME/.ghc-wasm"
    printf 'keep me\n' >"$HOME/.ghc-wasm/custom"
    printf 'touch "$HOME/env-was-sourced"\n' >"$HOME/.ghc-wasm/env"
  else
    sysroot
    case $kind in
      incomplete) rm "$HOME/.ghc-wasm/wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/libc.a" ;;
      wrong-revision) printf 'other\n' >"$HOME/.ghc-wasm/.paladyn-rev" ;;
    esac
  fi
  snapshot >"$case_dir/before"
  if bootstrap check >"$case_dir/check" 2>&1; then fail "$kind check succeeded"; fi
  if bootstrap toolchain >"$case_dir/install" 2>&1; then fail "$kind install succeeded"; fi
  snapshot >"$case_dir/after"
  cmp "$case_dir/before" "$case_dir/after" || fail "$kind sysroot was changed"
  assert_contains "$case_dir/install" 'refusing to overwrite'
  [ ! -s "$EVENTS" ] || fail "$kind ran mutation commands"
  pass "$kind sysroot is refused before writes or env execution"
done

fixture missing
NODE_REPORT=v23.11.0
export NODE_REPORT
bootstrap check >"$case_dir/check"
assert_contains "$case_dir/check" 'install Node 24.21.0'
assert_contains "$case_dir/check" 'install wasm sysroot'
[ ! -e "$HOME/.wiki-toolchain" ] || fail 'missing-tool inventory wrote state'
pass 'check lists missing sysroot and incompatible Node without installing'

# No sysroot, and no gitlab.haskell.org: the fake curl refuses every download,
# as a proxy that blocks the host does, so ghc-wasm-meta comes from the GitHub
# mirror and its setup.sh installs the sysroot.
fixture mirror
bootstrap toolchain >"$case_dir/install"
assert_contains "$EVENTS" "unexpected curl --fail --location --retry 5 --silent --show-error --output $HOME/.wiki-toolchain/ghc-wasm-meta-$REV.tmp.tar.gz https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta/-/archive/$REV/ghc-wasm-meta-$REV.tar.gz"
assert_contains "$case_dir/install" 'fetching the commit from the GitHub mirror'
assert_contains "$EVENTS" "git -C $HOME/.wiki-toolchain/ghc-wasm-meta-$REV.tmp fetch -q --depth 1 https://github.com/haskell-wasm/ghc-wasm-meta $REV"
assert_contains "$EVENTS" "setup.sh PREFIX=$HOME/.ghc-wasm SKIP_GHC=1 FLAVOUR="
[ -f "$HOME/.wiki-toolchain/ghc-wasm-meta-$REV/ghcup-wasm-0.0.9.yaml" ] || fail 'the mirror checkout was not kept'
[ ! -e "$HOME/.wiki-toolchain/ghc-wasm-meta-$REV/.git" ] || fail 'the mirror checkout kept its .git'
[ -f "$HOME/.ghc-wasm/.bootstrap-$REV" ] || fail 'the sysroot from the mirror was not stamped'
bootstrap check >"$case_dir/check"
assert_contains "$case_dir/check" 'reuse wasm sysroot'
pass 'ghc-wasm-meta comes from its GitHub mirror when gitlab.haskell.org refuses the archive'

# The toolchain under a directory WIKI_TOOLCHAIN_HOME names (a deployment's
# prefix): everything is found and installed there, the tools are told to
# keep their files there, and the home directory stays empty.
fixture named-base
base=$case_dir/srv/toolchain
sysroot "$base"
WIKI_TOOLCHAIN_HOME=$base
export WIKI_TOOLCHAIN_HOME
bootstrap check >"$case_dir/check"
assert_contains "$case_dir/check" "reuse wasm sysroot $base/.ghc-wasm"
bootstrap build >"$case_dir/build"
[ -f "$base/.wiki-toolchain/env" ] || fail 'build did not write the environment file under the named directory'
[ ! -e "$HOME/.wiki-toolchain" ] && [ ! -e "$HOME/.ghc-wasm" ] && [ ! -e "$HOME/.ghcup" ] || fail 'the named directory left something in the home directory'
bootstrap env >"$case_dir/env"
for line in "WIKI_TOOLCHAIN_HOME='$base'" "GHCUP_INSTALL_BASE_PREFIX='$base'" "CABAL_DIR='$base/.cabal'" "npm_config_cache='$base/.npm'" "PLAYWRIGHT_BROWSERS_PATH='$base/.cache/ms-playwright'"; do
  assert_contains "$case_dir/env" "$line"
  assert_contains "$base/.wiki-toolchain/env" "$line"
done
assert_contains "$case_dir/env" "$base/.wiki-toolchain/node/bin:$base/.ghcup/bin"
unset WIKI_TOOLCHAIN_HOME
bootstrap env >"$case_dir/env-home"
if grep -F 'CABAL_DIR' "$case_dir/env-home" >/dev/null; then fail 'the home directory layout exports the tools'"'"' variables'; fi
pass 'WIKI_TOOLCHAIN_HOME puts the toolchain under a named directory, with the tools told to keep their files there'

fixture wrong-playwright
sysroot
printf '{"version":"1.62.0"}\n' >"$case_dir/repo/node_modules/playwright-core/package.json"
bootstrap check >"$case_dir/check"
assert_contains "$case_dir/check" 'install playwright-core 1.63.0'
pass 'project Playwright must match the lockfile version'

readiness_fixture() {
  fixture "$1"
  sysroot
  cp "$SOURCE_DIR/check-npm-deps.cjs" "$SOURCE_DIR/npm-command.sh" "$SOURCE_DIR/test-native.sh" "$SOURCE_DIR/serve-wasm.sh" "$case_dir/repo/toolchain/"
  cp "$SOURCE_DIR/../package.json" "$case_dir/repo/package.json"
  mkdir -p "$HOME/.ghc-wasm/compiler/bin" "$case_dir/repo/node_modules/.bin"
  mv "$case_dir/bin/wasm32-wasi-ghc" "$HOME/.ghc-wasm/compiler/bin/wasm32-wasi-ghc"
  rm "$HOME/.ghc-wasm/compiler/bin/wasm32-wasi-ghc"
  # The compiler is intentionally absent from caller PATH. The real wasm
  # scripts source this env automatically and readiness must allow that.
  cp "$case_dir/bin/tool" "$HOME/.ghc-wasm/compiler/bin/wasm32-wasi-ghc"
  for cmd in wasm32-wasi-ghc-pkg wasm32-wasi-hsc2hs wasm-opt; do
    printf '#!/bin/sh\nexit 0\n' >"$HOME/.ghc-wasm/compiler/bin/$cmd"
    chmod +x "$HOME/.ghc-wasm/compiler/bin/$cmd"
  done
  printf 'export PATH="%s/compiler/bin:$PATH"\nexport CC=wasm-only-cc\n' "$HOME/.ghc-wasm" >"$HOME/.ghc-wasm/env"
  unset CC
  for package in esbuild katex highlight.js mermaid fflate @drgrice1/tikzjax http-server @bjorn3/browser_wasi_shim \
    @codemirror/state @codemirror/view @codemirror/commands @codemirror/language @codemirror/lang-markdown @codemirror/lint @lezer/highlight \
    @anthropic-ai/sdk openai cropperjs; do
    mkdir -p "$case_dir/repo/node_modules/$package"
    printf '{"main":"index.js"}\n' >"$case_dir/repo/node_modules/$package/package.json"
    printf 'module.exports = {};\n' >"$case_dir/repo/node_modules/$package/index.js"
  done
  mkdir -p "$case_dir/repo/node_modules/katex/dist" "$case_dir/repo/node_modules/highlight.js/lib/languages" \
    "$case_dir/repo/node_modules/@drgrice1/tikzjax/dist"
  touch "$case_dir/repo/node_modules/katex/dist/katex.min.css" \
    "$case_dir/repo/node_modules/@drgrice1/tikzjax/dist/run-tex.js" \
    "$case_dir/repo/node_modules/@drgrice1/tikzjax/dist/core.dump.gz" \
    "$case_dir/repo/node_modules/highlight.js/lib/common.js" \
    "$case_dir/repo/node_modules/highlight.js/lib/languages/haskell.js"
  printf '#!/bin/sh\nprintf "0.28.2\\n"\n' >"$case_dir/repo/node_modules/.bin/esbuild"
  cat >"$case_dir/repo/node_modules/.bin/http-server" <<'EOF'
#!/bin/sh
{ printf 'server'; printf ' <%s>' "$@"; printf '\n'; } >>"$EVENTS"
EOF
  chmod +x "$case_dir/repo/node_modules/.bin/"*
  cat >"$case_dir/repo/toolchain/build-wasm.sh" <<'EOF'
#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. "$HOME/.ghc-wasm/env"
{ printf 'wasm CC=%s project=%s builddir=%s' "$CC" "${WASM_PROJECT:-}" "${WASM_BUILDDIR:-}"; printf ' <%s>' "$@"; printf '\n'; } >>"$EVENTS"
mkdir -p "${WASM_BUILDDIR:-dist-newstyle/wasm}/public/app"
EOF
  # The test scripts stand in the same way: each records that it ran, with
  # the wasm CC it saw (none, since only the wasm scripts load that
  # environment themselves) and its arguments.
  for script in test-wasm run-tests dev-test; do
    cat >"$case_dir/repo/toolchain/$script.sh" <<EOF
#!/bin/sh
{ printf '$script CC=%s' "\${CC:-}"; printf ' <%s>' "\$@"; printf '\\n'; } >>"\$EVENTS"
EOF
  done
}

npm_command() {
  (cd "$case_dir/repo"; NO_OPEN=1 npm_config_update_notifier=false "$NPM_REAL" run "$@")
}

readiness_fixture ready
snapshot >"$case_dir/before"
bootstrap ready build-wasm >"$case_dir/ready"
snapshot >"$case_dir/after"
cmp "$case_dir/before" "$case_dir/after" || fail 'strict readiness mutated fixtures'
[ ! -s "$EVENTS" ] || fail 'strict readiness installed or launched something'
[ -z "${CC:-}" ] || fail 'wasm CC leaked into caller'
pass 'strict readiness is read-only and accepts automatically loaded wasm tools'

GHC_REPORT=9.12.2
export GHC_REPORT
for command in build serve build-native build-wasm build-wasm-opt serve-wasm test-native test-wasm test dev-test; do
  if npm_command "$command" >"$case_dir/$command" 2>&1; then fail "$command bypassed readiness"; fi
  assert_contains "$case_dir/$command" 'sh toolchain/bootstrap.sh toolchain'
  assert_contains "$case_dir/$command" '. ~/.wiki-toolchain/env'
  assert_contains "$case_dir/$command" 'found: 9.12.2'
done
[ ! -s "$EVENTS" ] || fail 'a rejected npm command reached build or server'
pass 'all ten npm entry points stop before compilation, tests or server startup on a wrong compiler'

GHC_REPORT=9.14.1
export GHC_REPORT
[ ! -e "$HOME/.wiki-toolchain/env" ] || fail 'ready PATH fixture unexpectedly has a generated environment'
npm_command build-native -- '--constraint=example ==1' -j2 >"$case_dir/native" 2>&1
assert_contains "$case_dir/native" 'cabal <build> <all> <--builddir=dist-newstyle/native> <--constraint=example ==1> <-j2>'
for command in build build-wasm serve serve-wasm; do
  : >"$EVENTS"
  npm_command "$command" -- '--constraint=example ==1' -j2 >"$case_dir/$command" 2>&1
  assert_contains "$EVENTS" 'wasm CC=wasm-only-cc project= builddir= <--constraint=example ==1> <-j2>'
  [ "$(grep -c 'bootstrap: ready for' "$case_dir/$command")" = 1 ] || fail "$command checked readiness twice"
  case $command in
    serve*) assert_contains "$EVENTS" 'server <.> <-p> <8080>' ;;
  esac
done
: >"$EVENTS"
npm_command build-wasm-opt -- -j2 >"$case_dir/build-wasm-opt" 2>&1
assert_contains "$EVENTS" 'wasm CC=wasm-only-cc project=cabal-wasm-opt.project builddir=dist-newstyle/wasm-opt <-j2>'
[ "$(grep -c 'bootstrap: ready for build-wasm-opt' "$case_dir/build-wasm-opt")" = 1 ] || fail 'build-wasm-opt checked readiness twice'
npm_command test-native -- -j2 >"$case_dir/test-native" 2>&1
assert_contains "$case_dir/test-native" 'cabal <test> <all> <--builddir=dist-newstyle/native> <-j2>'
for command in test-wasm test dev-test; do
  : >"$EVENTS"
  npm_command "$command" -- -j2 >"$case_dir/$command" 2>&1
  case $command in
    test-wasm) assert_contains "$EVENTS" 'test-wasm CC= <-j2>' ;;
    test) assert_contains "$EVENTS" 'run-tests CC= <-j2>' ;;
    dev-test) assert_contains "$EVENTS" 'dev-test CC= <-j2>' ;;
  esac
  [ "$(grep -c 'bootstrap: ready for' "$case_dir/$command")" = 1 ] || fail "$command checked readiness twice"
done
pass 'ready PATH works without an env file; npm delegates once, preserves arguments and uses the local server'

readiness_fixture unloaded
mkdir -p "$HOME/.ghcup/bin" "$HOME/.wiki-toolchain"
mv "$case_dir/bin/ghc" "$HOME/.ghcup/bin/ghc"
rm "$HOME/.ghcup/bin/ghc"
cp "$case_dir/bin/tool" "$HOME/.ghcup/bin/ghc"
printf 'export PATH="%s/.ghcup/bin:$PATH"\n' "$HOME" >"$HOME/.wiki-toolchain/env"
if bootstrap ready >"$case_dir/unloaded" 2>&1; then fail 'unloaded managed GHC passed'; fi
assert_contains "$case_dir/unloaded" 'ghc 9.14.1 is required on PATH'
bootstrap check >"$case_dir/inventory"
assert_contains "$case_dir/inventory" 'reuse ghc 9.14.1'
cp "$HOME/.wiki-toolchain/env" "$case_dir/env-before"
for command in build-native build build-wasm serve serve-wasm test-native test-wasm; do
  : >"$EVENTS"
  npm_command "$command" -- -j2 >"$case_dir/$command" 2>&1
  assert_contains "$case_dir/$command" 'bootstrap: ready for'
  case $command in
    build-native) assert_contains "$case_dir/$command" 'cabal <build> <all> <--builddir=dist-newstyle/native> <-j2>' ;;
    test-native) assert_contains "$case_dir/$command" 'cabal <test> <all> <--builddir=dist-newstyle/native> <-j2>' ;;
    test-wasm) assert_contains "$EVENTS" 'test-wasm CC= <-j2>' ;;
    *) assert_contains "$EVENTS" 'wasm CC=wasm-only-cc project= builddir= <-j2>' ;;
  esac
  case $command in
    serve*) assert_contains "$EVENTS" 'server <.> <-p> <8080>' ;;
  esac
done
cmp "$case_dir/env-before" "$HOME/.wiki-toolchain/env" || fail 'npm rewrote the environment file'
[ ! -e "$HOME/.wiki-toolchain/bootstrap.log" ] || fail 'npm ran an install mode'
if bootstrap ready >"$case_dir/still-unloaded" 2>&1; then fail 'npm changed caller PATH'; fi
. "$HOME/.wiki-toolchain/env"
bootstrap ready >"$case_dir/loaded"
pass 'direct readiness rejects unloaded PATH while every npm build, serve and test entry point automatically loads env'

readiness_fixture old-env
mkdir -p "$HOME/.ghcup/bin" "$HOME/.wiki-toolchain"
GHC_REPORT=9.12.2
export GHC_REPORT
# Managed GHC is pinned even while an incompatible user installation wins
# on the initial PATH. The old env file wrongly skips a directory already there.
printf '#!/bin/sh\nprintf "9.14.1\\n"\n' >"$HOME/.ghcup/bin/ghc"
chmod +x "$HOME/.ghcup/bin/ghc"
PATH=$PATH:$HOME/.ghcup/bin:$HOME/.wiki-toolchain/node/bin:$HOME/.ghcup/bin
export PATH
printf 'case ":$PATH:" in *":%s/.ghcup/bin:"*) ;; *) PATH="%s/.ghcup/bin:$PATH" ;; esac\nexport PATH\n' \
  "$HOME" "$HOME" >"$HOME/.wiki-toolchain/env"
cp "$HOME/.wiki-toolchain/env" "$case_dir/env-before"
if bootstrap ready >"$case_dir/before" 2>&1; then fail 'initial old PATH unexpectedly passed'; fi
npm_command serve-wasm -- -j2 >"$case_dir/serve" 2>&1
assert_contains "$EVENTS" 'wasm CC=wasm-only-cc project= builddir= <-j2>'
assert_contains "$EVENTS" 'server <.> <-p> <8080>'
cmp "$case_dir/env-before" "$HOME/.wiki-toolchain/env" || fail 'npm rewrote an old env file'
generated_env=$(bootstrap env)
eval "$generated_env"
expected_path=$HOME/.wiki-toolchain/node/bin:$HOME/.ghcup/bin:$case_dir/bin:/usr/bin:/bin
[ "$PATH" = "$expected_path" ] || fail "managed PATH precedence/duplicates: $PATH"
eval "$generated_env"
[ "$PATH" = "$expected_path" ] || fail 'sourcing generated env twice duplicated PATH entries'
bootstrap ready >"$case_dir/after"
pass 'old env files work automatically; fresh directives put managed tools first and are idempotent'

readiness_fixture registry-path
mv "$CACHE/chrome-headless-shell-linux64/$CHROMIUM_NAME" "$CACHE/chrome-headless-shell-linux64/reported-shell"
CHROMIUM_NAME=reported-shell
export CHROMIUM_NAME
snapshot >"$case_dir/before"
bootstrap ready >"$case_dir/ready"
bootstrap check >"$case_dir/check"
snapshot >"$case_dir/after"
cmp "$case_dir/before" "$case_dir/after" || fail 'registry cache discovery changed files'
assert_contains "$case_dir/check" 'reuse Chromium cache'
[ ! -s "$EVENTS" ] || fail 'registry cache discovery installed or launched Chromium'
pass 'Chromium cache detection follows the installed registry executable path without writes'

readiness_fixture missing-npm
rm "$case_dir/repo/node_modules/mermaid/index.js"
if npm_command build >"$case_dir/missing" 2>&1; then fail 'partial node_modules passed'; fi
assert_contains "$case_dir/missing" 'npm package mermaid'
assert_contains "$case_dir/missing" 'npm ci'
[ ! -s "$EVENTS" ] || fail 'missing npm package reached build'
bootstrap ready build-native >"$case_dir/native"
rm "$case_dir/repo/node_modules/.bin/http-server"
if npm_command serve >"$case_dir/missing-server" 2>&1; then fail 'missing local http-server passed'; fi
assert_contains "$case_dir/missing-server" 'npm package http-server'
[ ! -s "$EVENTS" ] || fail 'missing server package reached build or downloaded a replacement'
pass 'partial npm dependencies and missing local executables fail with npm ci instructions'

readiness_fixture pins
rm "$CACHE/chrome-headless-shell-linux64/$CHROMIUM_NAME"
if bootstrap ready test-wasm >"$case_dir/chromium" 2>&1; then fail 'missing Chromium passed readiness for a browser test'; fi
assert_contains "$case_dir/chromium" 'Chromium headless shell'
[ ! -s "$EVENTS" ] || fail 'strict readiness tried repairing a missing tool'
pass 'strict checks reject missing Chromium without repairs'

# Each command is gated on what it needs: a hosted CI runner has the host GHC
# and cabal alone for the native job, and the wasm job installs Chromium only
# after its build; fourmolu is nobody's, since `npm run format` runs it itself.
readiness_fixture needs
rm "$case_dir/bin/fourmolu" "$CACHE/chrome-headless-shell-linux64/$CHROMIUM_NAME"
bootstrap ready build-wasm >"$case_dir/wasm-no-browser"
assert_contains "$case_dir/wasm-no-browser" 'ready for build-wasm'
rm "$case_dir/bin/node" "$case_dir/bin/npm"
# The host may already have Node 24 in /usr/bin. An explicit old mock
# makes this case independent of the machine running the test.
ln -s tool "$case_dir/bin/node"
ln -s tool "$case_dir/bin/npm"
NODE_REPORT=v18.0.0
export NODE_REPORT
rm -r "$HOME/.ghc-wasm"
for command in build-native test-native; do
  bootstrap ready "$command" >"$case_dir/$command"
  assert_contains "$case_dir/$command" "ready for $command"
done
if bootstrap ready build-wasm >"$case_dir/wasm-native-only" 2>&1; then fail 'a wasm build passed readiness with the host tools alone'; fi
assert_contains "$case_dir/wasm-native-only" 'wasm sysroot'
assert_contains "$case_dir/wasm-native-only" 'Node >=24'
if grep -F fourmolu "$case_dir/wasm-native-only" >/dev/null; then fail 'readiness asked for fourmolu'; fi
[ ! -s "$EVENTS" ] || fail 'per-command readiness installed or launched something'
pass 'the native commands need the host GHC and cabal alone; the wasm build needs no browser; nothing needs fourmolu'

readiness_fixture wasm-shadow
printf 'export NODE_REPORT=v23.11.0\n' >>"$HOME/.ghc-wasm/env"
if bootstrap ready >"$case_dir/wasm-node" 2>&1; then fail 'wasm environment shadowed compatible Node'; fi
assert_contains "$case_dir/wasm-node" 'wasm environment must provide Node >=24'
pass 'effective wasm environment cannot hide incompatible Node behind a compatible caller'

# --system-tools: the machine's own GHC, cabal and Node, which the
# bootstrap checks first and never installs. These runs get a PATH of the
# fake tools and links to the host's commands without its own ghc, cabal,
# node and npm, so that a missing tool is missing whatever the host has.
fixture system-tools
# The native case's fakes of what toolchain/check-native.sh checks.
cp "$TMP/native/bin/cc" "$TMP/native/bin/pkg-config" "$case_dir/bin/"
printf '#!/bin/sh\nprintf "/usr/lib/postgresql/17/bin\\n"\n' >"$case_dir/bin/pg_config"
printf '#!/bin/sh\nexit 0\n' >"$case_dir/bin/make"
chmod +x "$case_dir/bin/pg_config" "$case_dir/bin/make"
no_tools=$case_dir/no-tools
mkdir "$no_tools"
for cmd in /usr/bin/* /bin/*; do
  name=${cmd##*/}
  case $name in ghc* | cabal* | node | npm | npx) continue ;; esac
  if [ ! -f "$cmd" ] || [ ! -x "$cmd" ]; then continue; fi
  [ -e "$no_tools/$name" ] || [ -L "$no_tools/$name" ] || ln -s "$cmd" "$no_tools/$name"
done
PATH=$case_dir/bin:$no_tools
export PATH
rm "$case_dir/bin/node"
status=0
GHC_REPORT=9.10.3 CABAL_REPORT=3.10.3.0 bootstrap system-tools native node >"$case_dir/old" 2>&1 || status=$?
[ "$status" = 1 ] || fail "system-tools with old tools exited $status, not 1"
assert_contains "$case_dir/old" "bootstrap: --system-tools: GHC 9.10.3 ($case_dir/bin/ghc) is too old: GHC 9.12 or later is needed: haskell-halogen-th, which the wiki builds with, parses quotes with the compiler's own ghc library and asks for ghc 9.12 or later. Without --system-tools, toolchain/bootstrap.sh installs GHC 9.14.1"
assert_contains "$case_dir/old" "bootstrap: --system-tools: cabal 3.10.3.0 ($case_dir/bin/cabal) is too old: cabal 3.12 or later is needed: cabal.project sets semaphore:, a field cabal reads from 3.12. Without --system-tools, toolchain/bootstrap.sh installs cabal 3.16.1.0"
assert_contains "$case_dir/old" 'bootstrap: --system-tools: Node: not found (no node on PATH answers --version). Node 24 or later with npm is needed. Without --system-tools, toolchain/bootstrap.sh installs Node 24.21.0, with its npm'
assert_contains "$case_dir/old" 'bootstrap: --system-tools: this machine lacks what is named above, so nothing was installed or changed'
rm "$case_dir/bin/ghc" "$case_dir/bin/cabal"
ln -s tool "$case_dir/bin/node"
status=0
NODE_REPORT=v22.11.0 bootstrap system-tools >"$case_dir/missing" 2>&1 || status=$?
[ "$status" = 1 ] || fail "system-tools without GHC and cabal exited $status, not 1"
assert_contains "$case_dir/missing" 'bootstrap: --system-tools: GHC: not found (no ghc on PATH answers --numeric-version). GHC 9.12 or later is needed'
assert_contains "$case_dir/missing" 'bootstrap: --system-tools: cabal: not found (no cabal on PATH answers --numeric-version). cabal 3.12 or later is needed'
assert_contains "$case_dir/missing" "bootstrap: --system-tools: Node v22.11.0 ($case_dir/bin/node) is too old: Node 24 or later with npm is needed"
ln -s tool "$case_dir/bin/ghc"
ln -s tool "$case_dir/bin/cabal"
status=0
GHC_REPORT=9.14.1 bootstrap native --system-tools >"$case_dir/native-no-node" 2>&1 || status=$?
[ "$status" = 0 ] || fail "native --system-tools asked for Node: $(cat "$case_dir/native-no-node")"
[ ! -e "$HOME/.wiki-toolchain/bootstrap.log" ] || [ -n "$(cat "$HOME/.wiki-toolchain/bootstrap.log")" ] || fail 'native --system-tools left an empty log'
rm -rf "$HOME/.wiki-toolchain"
status=0
GHC_REPORT=9.10.3 bootstrap native --system-tools >"$case_dir/native-old" 2>&1 || status=$?
[ "$status" = 1 ] || fail "native --system-tools with GHC 9.10.3 exited $status, not 1"
assert_contains "$case_dir/native-old" 'GHC 9.10.3'
[ ! -e "$HOME/.wiki-toolchain" ] || fail 'native --system-tools with a GHC too old changed something before it stopped'
[ ! -s "$EVENTS" ] || fail "the check of the machine's tools installed something: $(cat "$EVENTS")"
pass '--system-tools refuses a GHC, cabal or Node that is missing or older than its floor, naming each, before anything else'

GHC_REPORT=9.12.2 CABAL_REPORT=3.12.1.0 NODE_REPORT=v24.3.0 bootstrap system-tools native node >"$case_dir/new" 2>&1 ||
  fail "system-tools with GHC 9.12.2, cabal 3.12.1.0 and Node 24 failed: $(cat "$case_dir/new")"
assert_contains "$case_dir/new" "bootstrap: --system-tools: GHC 9.12.2 ($case_dir/bin/ghc)"
assert_contains "$case_dir/new" "bootstrap: warning: the pinned GHC is 9.14.1; the build with 9.12.2 is untested here and may fail; a failure then is not this script's"
assert_contains "$case_dir/new" "bootstrap: warning: the pinned cabal is 3.16.1.0; the build with 3.12.1.0 is untested here and may fail; a failure then is not this script's"
assert_contains "$case_dir/new" "bootstrap: --system-tools: Node v24.3.0 ($case_dir/bin/node), npm 11.0.0 ($case_dir/bin/npm)"
[ ! -e "$HOME/.wiki-toolchain" ] || fail 'system-tools, a check, wrote something'
GHC_REPORT=9.12.2 bootstrap native --system-tools >"$case_dir/native" 2>&1 ||
  fail "native --system-tools with GHC 9.12.2 failed: $(cat "$case_dir/native")"
assert_contains "$case_dir/native" "this machine's GHC 9.12.2 and cabal 3.16.1.0 (--system-tools); no wasm toolchain, Node, Chromium or fourmolu (native)"
assert_contains "$case_dir/native" 'the pinned GHC is 9.14.1; the build with 9.12.2 is untested here'
[ ! -e "$HOME/.ghcup" ] || fail 'native --system-tools installed ghcup'
if grep -E '^(PATH=|export PATH)' "$HOME/.wiki-toolchain/env" >/dev/null; then fail "native --system-tools put its directories on PATH: $(cat "$HOME/.wiki-toolchain/env")"; fi
NODE_REPORT=v24.3.0 bootstrap node --system-tools >"$case_dir/node" 2>&1 ||
  fail "node --system-tools failed: $(cat "$case_dir/node")"
assert_contains "$case_dir/node" "this machine's Node v24.3.0 (--system-tools)"
[ ! -e "$HOME/.wiki-toolchain/node" ] || fail 'node --system-tools installed Node'
[ ! -s "$EVENTS" ] || fail "--system-tools downloaded or installed something: $(cat "$EVENTS")"
status=0
bootstrap build --system-tools >"$case_dir/build" 2>&1 || status=$?
[ "$status" = 2 ] || fail "build --system-tools exited $status, not 2"
assert_contains "$case_dir/build" "bootstrap: build takes no --system-tools: the page's build needs the wasm toolchain, which the bootstrap installs (--system-tools is for native and node)"
pass '--system-tools takes a GHC, cabal and Node at their floors or later, with a warning for each that is not the pinned version, and installs none; build refuses it'

# --hackage-mirror=URL: written into the toolchain's own cabal
# configuration (CABAL_DIR under WIKI_TOOLCHAIN_HOME), which cabal
# user-config init writes first, after the mirror's root.json is fetched;
# the index is updated again from it; the user's ~/.cabal is untouched.
# Without a toolchain directory of its own the option is refused. A run
# without it puts Hackage's own url back.
rm "$case_dir/bin/curl"
cat >"$case_dir/bin/curl" <<'EOF'
#!/bin/sh
output=
for arg do
  case $arg in --output) output=next ;; *) [ "$output" != next ] || output=$arg ;; esac
done
for url do :; done
printf 'curl %s\n' "$url" >>"$EVENTS"
case $url in
  */root.json) [ -z "${FAKE_NO_ROOT:-}" ] || { printf 'curl: (22) The requested URL returned error: 404\n' >&2; exit 22; }
    printf '{"signed":{}}\n' >"$output" ;;
  *) exit 91 ;;
esac
EOF
chmod +x "$case_dir/bin/curl"
mkdir -p "$HOME/.cabal"
printf 'repository hackage.haskell.org\n  url: http://the-users-own.example/\n' >"$HOME/.cabal/config"
cp "$HOME/.cabal/config" "$case_dir/users-config"
status=0
bootstrap native --hackage-mirror=https://hackage.example.org >"$case_dir/mirror-home" 2>&1 || status=$?
[ "$status" = 2 ] || fail "--hackage-mirror without a toolchain directory exited $status, not 2"
assert_contains "$case_dir/mirror-home" "bootstrap: --hackage-mirror writes the mirror into the toolchain's own cabal configuration, which exists only under a WIKI_TOOLCHAIN_HOME other than the home directory"
tc=$case_dir/tc
: >"$EVENTS"
WIKI_TOOLCHAIN_HOME=$tc bootstrap native --system-tools --hackage-mirror=https://hackage.example.org >"$case_dir/mirror" 2>&1 ||
  fail "native --hackage-mirror failed: $(cat "$case_dir/mirror")"
assert_contains "$EVENTS" 'curl https://hackage.example.org/root.json'
assert_contains "$EVENTS" "cabal user-config init CABAL_DIR=$tc/.cabal"
assert_contains "$EVENTS" 'cabal update'
{ [ "$(line_of "$EVENTS" 'root.json')" -lt "$(line_of "$EVENTS" 'user-config')" ] &&
  [ "$(line_of "$EVENTS" 'user-config')" -lt "$(line_of "$EVENTS" 'cabal update')" ]; } ||
  fail "the mirror was not checked, written and then updated from, in that order: $(cat "$EVENTS")"
assert_contains "$case_dir/mirror" "bootstrap: cabal's index and packages come from the Hackage mirror https://hackage.example.org/: written into $tc/.cabal/config"
sed -n '/^repository hackage.haskell.org$/,/^$/p' "$tc/.cabal/config" >"$case_dir/stanza"
[ "$(cat "$case_dir/stanza")" = "$(printf 'repository hackage.haskell.org\n  url: https://hackage.example.org/\n  secure: True\n  -- url: written by toolchain/bootstrap.sh --hackage-mirror\n  -- secure: True\n  -- root-keys:\n')" ] ||
  fail "the stanza is not as expected: $(cat "$case_dir/stanza")"
# shellcheck disable=SC2016 # cabal's own text, $ncpus included, kept from its default configuration.
assert_contains "$tc/.cabal/config" 'jobs: $ncpus'
cmp "$HOME/.cabal/config" "$case_dir/users-config" || fail 'the user'"'"'s ~/.cabal/config changed'
# The environment of the machine's own tools still names the toolchain's
# CABAL_DIR, so that the deploy's cabal build reads the mirror written
# there; it only puts nothing first on PATH.
WIKI_TOOLCHAIN_HOME=$tc bootstrap env --system-tools >"$case_dir/env-system"
assert_contains "$case_dir/env-system" "CABAL_DIR='$tc/.cabal'"
assert_contains "$tc/.wiki-toolchain/env" "CABAL_DIR='$tc/.cabal'"
if grep -E '^(PATH=|export PATH)' "$case_dir/env-system" "$tc/.wiki-toolchain/env" >/dev/null; then fail 'the environment of --system-tools sets PATH'; fi
: >"$EVENTS"
WIKI_TOOLCHAIN_HOME=$tc bootstrap native --system-tools --hackage-mirror=https://hackage.example.org/ >"$case_dir/mirror-again" 2>&1 ||
  fail "native --hackage-mirror again failed: $(cat "$case_dir/mirror-again")"
[ ! -s "$EVENTS" ] || fail "the same mirror again fetched or updated something: $(cat "$EVENTS")"
cp "$tc/.cabal/config" "$case_dir/mirror-config"
: >"$EVENTS"
status=0
FAKE_NO_ROOT=1 WIKI_TOOLCHAIN_HOME=$tc bootstrap native --system-tools --hackage-mirror=https://other.example.org/ >"$case_dir/mirror-no-root" 2>&1 || status=$?
[ "$status" = 1 ] || fail "a mirror without root.json exited $status, not 1"
assert_contains "$case_dir/mirror-no-root" "bootstrap: the Hackage mirror https://other.example.org/ does not serve root.json"
cmp "$tc/.cabal/config" "$case_dir/mirror-config" || fail 'a mirror without root.json changed the configuration'
: >"$EVENTS"
WIKI_TOOLCHAIN_HOME=$tc bootstrap native --system-tools >"$case_dir/mirror-gone" 2>&1 ||
  fail "native without the mirror failed: $(cat "$case_dir/mirror-gone")"
assert_contains "$case_dir/mirror-gone" "bootstrap: cabal's index and packages come from Hackage again: its url written back into $tc/.cabal/config"
assert_contains "$EVENTS" 'cabal update'
sed -n '/^repository hackage.haskell.org$/,/^$/p' "$tc/.cabal/config" >"$case_dir/stanza"
[ "$(cat "$case_dir/stanza")" = "$(printf 'repository hackage.haskell.org\n  url: http://hackage.haskell.org/\n  -- secure: True\n  -- root-keys:\n')" ] ||
  fail "Hackage's url was not written back: $(cat "$case_dir/stanza")"
cmp "$HOME/.cabal/config" "$case_dir/users-config" || fail 'the user'"'"'s ~/.cabal/config changed'
pass '--hackage-mirror is checked for root.json, written into the toolchain'"'"'s own cabal configuration with secure: True, and the index updated from it; ~/.cabal is untouched; without it Hackage comes back'

printf 'Passed %s bootstrap regression cases.\n' "$passed"
