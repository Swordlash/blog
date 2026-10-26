#!/bin/sh
# Exercise discovery and install-mode reuse without touching the developer's
# home, network, package manager or real toolchain.
set -eu

SOURCE=$(cd "$(dirname "$0")" && pwd)/bootstrap.sh
SOURCE_DIR=${SOURCE%/*}
NODE_REAL=$(command -v node)
NPM_REAL=$(command -v npm)
export NODE_REAL
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
REV=358ea50b8496a69da6ce375c0c58bc049dbcb92d
passed=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 lacks: $2"; }
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$*"; }

fixture() {
  case_dir=$TMP/$1
  mkdir -p "$case_dir/home" "$case_dir/bin" "$case_dir/repo/toolchain"
  cp "$SOURCE" "$case_dir/repo/toolchain/bootstrap.sh"
  HOME=$case_dir/home
  EVENTS=$case_dir/events
  CACHE=$case_dir/cache/chromium_headless_shell-1234
  CHROMIUM_NAME=chrome-headless-shell
  PATH=$case_dir/bin:/usr/bin:/bin
  NODE_REPORT=v24.99.0 GHC_REPORT=9.14.1 HAPPY_REPORT=2.1.7 ALEX_REPORT=3.5.4.2
  export HOME EVENTS CACHE CHROMIUM_NAME PATH NODE_REPORT GHC_REPORT HAPPY_REPORT ALEX_REPORT
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
      --numeric-version) printf '3.16.1.0\n' ;;
      path) printf '%s/index\n' "$HOME" ;;
      build | test) printf 'cabal'; printf ' <%s>' "$@"; printf '\n' ;;
      install)
        printf 'cabal %s\n' "$*" >>"$EVENTS"
        for arg do case $arg in --installdir=*) dest=${arg#*=} ;; esac; done
        case $2 in
          happy-*) printf '#!/bin/sh\nprintf "Happy Version 2.1.7\\n"\n' >"$dest/happy"; chmod +x "$dest/happy" ;;
          alex-*) printf '#!/bin/sh\nprintf "Alex version 3.5.4.2\\n"\n' >"$dest/alex"; chmod +x "$dest/alex" ;;
          *) exit 91 ;;
        esac ;;
      *) printf 'unexpected cabal %s\n' "$*" >>"$EVENTS"; exit 91 ;;
    esac ;;
  node)
    if [ "${1:-}" = --version ]; then printf '%s\n' "$NODE_REPORT"; else exec "$NODE_REAL" "$@"; fi ;;
  npm) printf 'unexpected npm %s\n' "$*" >>"$EVENTS"; exit 91 ;;
  alex) [ "$1" = --version ] || exit 1; printf 'Alex version %s, (c) 2003 Chris Dornan and Simon Marlow\n' "$ALEX_REPORT" ;;
  happy) [ "$1" = --version ] || exit 1; printf 'Happy Version %s Copyright (c) 1993-1996 Andy Gill, Simon Marlow (c) 1997-2005 Simon Marlow\n' "$HAPPY_REPORT" ;;
  fourmolu) printf 'fourmolu 0.21.0.0\n' ;;
  dpkg-query) printf 'install ok installed\n' ;;
  curl|apt-get|sudo) printf 'unexpected %s %s\n' "$name" "$*" >>"$EVENTS"; exit 91 ;;
  *) exit 91 ;;
esac
EOF
  chmod +x "$case_dir/bin/tool"
  for cmd in ghc cabal wasm32-wasi-ghc node npm alex happy fourmolu dpkg-query curl apt-get sudo; do
    ln -s tool "$case_dir/bin/$cmd"
  done
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

sysroot() {
  prefix=$HOME/.ghc-wasm
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
assert_contains "$case_dir/check" 'reuse alex 3.5.4.2'
assert_contains "$case_dir/check" 'reuse happy 2.1.7'
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
pass 'build installs the compilers and Node, and neither Chromium nor fourmolu'

fixture generators
sysroot
HAPPY_REPORT=2.1.70
export HAPPY_REPORT
bootstrap check >"$case_dir/check"
assert_contains "$case_dir/check" 'install happy 2.1.7 (found: 2.1.70)'
bootstrap toolchain >"$case_dir/install"
assert_contains "$EVENTS" 'cabal install happy-2.1.7 --ignore-project'
assert_contains "$EVENTS" "--with-compiler=$case_dir/bin/ghc"
if grep -F 'alex-' "$EVENTS" >/dev/null; then fail 'matching alex was reinstalled'; fi
: >"$EVENTS"
bootstrap toolchain >"$case_dir/repeat"
[ "$(cat "$EVENTS")" = 'chromium launch' ] || fail 'happy was reinstalled after repair'
pass 'generators use --version, match whole versions and install only the missing pin'

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

fixture wrong-playwright
sysroot
printf '{"version":"1.62.0"}\n' >"$case_dir/repo/node_modules/playwright-core/package.json"
bootstrap check >"$case_dir/check"
assert_contains "$case_dir/check" 'install playwright-core 1.63.0'
pass 'project Playwright must match the lockfile version'

readiness_fixture() {
  fixture "$1"
  sysroot
  cp "$SOURCE_DIR/check-npm-deps.cjs" "$SOURCE_DIR/npm-command.sh" "$SOURCE_DIR/serve-wasm.sh" "$case_dir/repo/toolchain/"
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
    @codemirror/state @codemirror/view @codemirror/commands @codemirror/language @codemirror/lang-markdown @lezer/highlight; do
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
cp "$case_dir/bin/tool" "$HOME/.ghcup/bin/happy"
HAPPY_REPORT=2.1.70
export HAPPY_REPORT
# Managed happy is pinned even while an incompatible user installation wins
# on the initial PATH. The old env file wrongly skips a directory already there.
printf '#!/bin/sh\nprintf "Happy Version 2.1.7\\n"\n' >"$HOME/.ghcup/bin/happy"
chmod +x "$HOME/.ghcup/bin/happy"
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
HAPPY_REPORT=2.1.70
export HAPPY_REPORT
if bootstrap ready >"$case_dir/generator" 2>&1; then fail 'wrong generator passed readiness'; fi
assert_contains "$case_dir/generator" 'happy 2.1.7 is required'
HAPPY_REPORT=2.1.7
export HAPPY_REPORT
rm "$CACHE/chrome-headless-shell-linux64/$CHROMIUM_NAME"
if bootstrap ready test-wasm >"$case_dir/chromium" 2>&1; then fail 'missing Chromium passed readiness for a browser test'; fi
assert_contains "$case_dir/chromium" 'Chromium headless shell'
[ ! -s "$EVENTS" ] || fail 'strict readiness tried repairing a missing tool'
pass 'strict checks reject generator pins and missing Chromium without repairs'

# Each command is gated on what it needs: a hosted CI runner has the host GHC
# and cabal alone for the native job, and the wasm job installs Chromium only
# after its build; fourmolu is nobody's, since `npm run format` runs it itself.
readiness_fixture needs
rm "$case_dir/bin/fourmolu" "$CACHE/chrome-headless-shell-linux64/$CHROMIUM_NAME"
bootstrap ready build-wasm >"$case_dir/wasm-no-browser"
assert_contains "$case_dir/wasm-no-browser" 'ready for build-wasm'
rm "$case_dir/bin/alex" "$case_dir/bin/happy" "$case_dir/bin/node" "$case_dir/bin/npm"
rm -r "$HOME/.ghc-wasm"
for command in build-native test-native; do
  bootstrap ready "$command" >"$case_dir/$command"
  assert_contains "$case_dir/$command" "ready for $command"
done
if bootstrap ready build-wasm >"$case_dir/wasm-native-only" 2>&1; then fail 'a wasm build passed readiness with the host tools alone'; fi
assert_contains "$case_dir/wasm-native-only" 'alex 3.5.4.2 is required'
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

printf 'Passed %s bootstrap regression cases.\n' "$passed"
