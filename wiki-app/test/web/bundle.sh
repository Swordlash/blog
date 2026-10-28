#!/bin/sh
# What the browser test runner loads before the suite, as the application's
# page has it: the islands' scripts and styles (the same bundle the page is
# served with), and the page's own style sheet, by which the editor shows its
# preview and hides its Markdown.
#
# The runner loads every script here into its page as a classic script, so
# what the bundle writes for the application's own page alone goes: the
# service worker (sw.js), which is no page's script, and the WASI shim
# (wasi-shim.js), a module the runner brings its own of.
#
# And the page's Content Security Policy, which a script puts on the
# runner's page before anything else runs (policy.mjs writes it as
# 0-policy.js), so that the suite runs under the policy the application has.
set -eu
web="$(dirname "$0")/../../../web"
sh "$web/bundle.sh" "$1"
rm -f "$1/sw.js" "$1/wasi-shim.js"
cp "$web/style.css" "$1/style.css"
node "$(dirname "$0")/policy.mjs" "$web/index.html" "$1/0-policy.js"
