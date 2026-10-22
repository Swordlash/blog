#!/bin/sh
# Browser-GHCi loop for a browser test suite: the suite runs in a Chromium
# window, and ghciwatch reruns it (:main) on every save. Adapted from
# haskell-halogen's script of the same name.
#
#   sh toolchain/dev-test.sh                            # wiki-app's browser suite
#   sh toolchain/dev-test.sh wiki-app wiki-app-browser-test
#   sh toolchain/dev-test.sh --repl wiki-app            # plain GHCi, for :main --match "/Mermaid/";
#   sh toolchain/dev-test.sh --open-browser wiki-app    # then open its page from another terminal
#
# The suite must have an `interactive` flag that drops its reactor options, as
# wiki-app-browser-test does. The page is opened through Playwright
# (hspec-halogen open) so that the suite's clicks and keystrokes are real
# input. The watch loop needs ghciwatch on PATH; --repl and --open-browser do
# not.
set -eu

cd "$(dirname "$0")/.."

# The opener is the native hspec-halogen executable: build it before the wasm
# toolchain takes over the environment.
case "${1:-}" in
  --repl) ;;
  *)
    HSPEC_HALOGEN=${HSPEC_HALOGEN:-$(sh toolchain/build-hspec-halogen.sh)}
    export HSPEC_HALOGEN
    ;;
esac

. "$HOME/.ghc-wasm/env"
export PATH="$HOME/.local/bin:$PATH"

self=toolchain/dev-test.sh
mode=watch
case "${1:-}" in
  --repl|--open-browser) mode=${1#--}; shift ;;
esac

package=${1:-wiki-app}
cabal_file=$(ls "$package"/*.cabal)
package_name=$(basename "$cabal_file" .cabal)
# A package's browser suite is the one named <package>-browser-test; its other
# suites run natively and under Node, not in browser GHCi.
suite=${2:-$package_name-browser-test}
port=${PORT:-8080}
# Absolute, because GHCi resolves the assets directory from the package
# directory, which is where cabal starts it.
public_dir=$(pwd)/dist-newstyle/wasm-dev/$package-test/public

case "$port" in
  ''|*[!0-9]*) printf 'PORT must be a number.\n' >&2; exit 1 ;;
esac

# The page the suite runs in: the package's test/web assets, bundled as the
# runner bundles them (the islands under islands/ and fonts/ included), around
# browser GHCi's own script.
prepare_page() {
  rm -rf "$public_dir"
  mkdir -p "$public_dir"
  if [ -f "$package/test/web/bundle.sh" ]; then
    sh "$package/test/web/bundle.sh" "$public_dir"
  fi
  find "$package/test/web" -maxdepth 1 \( -name '*.css' -o -name '*.js' \) -exec cp {} "$public_dir" \; 2>/dev/null || true
  {
    printf '<!doctype html>\n<html lang="en">\n  <head>\n    <meta charset="utf-8">\n'
    printf '    <title>%s tests (browser GHCi)</title>\n' "$package_name"
    for asset in "$public_dir"/*.css; do [ -e "$asset" ] && printf '    <link rel="stylesheet" href="./%s">\n' "$(basename "$asset")"; done
    for asset in "$public_dir"/*.js; do [ -e "$asset" ] && printf '    <script src="./%s"></script>\n' "$(basename "$asset")"; done
    printf '    <script type="module" src="../main.js"></script>\n  </head>\n  <body></body>\n</html>\n'
  } > "$public_dir/index.html"
}

case "$mode" in
  open-browser)
    url="http://127.0.0.1:$port/assets/index.html"
    attempts=0
    until curl --fail --silent --max-time 1 --output /dev/null "$url"; do
      attempts=$((attempts + 1))
      if [ "$attempts" -ge 3600 ]; then
        printf 'Browser GHCi is not serving %s.\n' "$url" >&2
        exit 1
      fi
      sleep 1
    done
    exec "$HSPEC_HALOGEN" open "$url"
    ;;
  repl)
    [ -f "$public_dir/index.html" ] || prepare_page
    # Cabal may reuse the host ghc-pkg from this cache when switching toolchains,
    # and miss a change to cabal.project, which cabal-wasm.project imports, in
    # this one (see build-wasm.sh).
    rm -f dist-newstyle/wasm-dev/cache/compiler dist-newstyle/wasm-dev/cache/config
    # Browser GHCi's interpreter needs ghc-wasm-meta's npm packages (ws).
    # ~/.ghc-wasm/env points NODE_PATH at them only when it was unset, and a
    # shell (a cloud session's) may have set it already.
    NODE_PATH="${NODE_PATH:+$NODE_PATH:}$HOME/.ghc-wasm/nodejs/lib/node_modules"
    export NODE_PATH
    # -Wwarn undoes cabal.project's -Werror for the suite GHCi loads: an unused
    # import halfway through an edit shouldn't stop the tests from rerunning.
    exec cabal repl --project-file=cabal-wasm.project \
      --with-compiler="$(command -v wasm32-wasi-ghc)" \
      --with-hc-pkg="$(command -v wasm32-wasi-ghc-pkg)" \
      --with-hsc2hs="$(command -v wasm32-wasi-hsc2hs)" \
      --builddir=dist-newstyle/wasm-dev --disable-multi-repl --enable-shared \
      --constraint="$package_name +interactive" \
      "$package_name:test:$suite" \
      --repl-options="-Wwarn -fghci-browser -fghci-browser-port=$port -fghci-browser-assets-dir=$public_dir"
    ;;
esac

if ! command -v ghciwatch >/dev/null 2>&1; then
  printf 'Install ghciwatch: https://mercurytechnologies.github.io/ghciwatch/\nFor manual runs, use: sh %s --repl %s\n' "$self" "$package" >&2
  exit 1
fi

prepare_page

# The page is opened here rather than as a ghciwatch hook, whose output
# ghciwatch keeps to itself: the suite's report is printed by the opener. It
# reloads the page by itself whenever GHCi restarts.
sh "$self" --open-browser "$package" "$suite" &
opener=$!
trap 'kill "$opener" 2>/dev/null' EXIT INT TERM

# Test modules reload in place; a change to the package's library, the islands
# bundle or a cabal file needs GHCi restarted (and the page rebundled) to
# take effect.
ghciwatch \
  --command "sh $self --repl $package $suite" \
  --watch "$package/test" --watch "$package/src" \
  --restart-glob "$package/src/**" --restart-glob "$package/jsbits/**" \
  --restart-glob "**/*.cabal" --restart-glob cabal-wasm.project \
  --after-startup-ghci ':main' --after-reload-ghci ':main' --debounce 100ms --poll 500ms
