#!/bin/sh
# Open a URL in the desktop's browser, where there is one (serve-wasm.sh).
#
#   sh toolchain/open-browser.sh http://127.0.0.1:8080
set -eu

url=$1

case "$(uname -s)" in
  Darwin)
    open "$url"
    ;;
  Linux)
    if command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$url"
    fi
    ;;
esac
