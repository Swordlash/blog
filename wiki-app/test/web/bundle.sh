#!/bin/sh
# What the browser test runner loads before the suite, as the application's
# page has it: the islands' scripts and styles (the same bundle the page is
# served with), and the page's own style sheet, by which the editor shows its
# preview and hides its Markdown.
set -eu
web="$(dirname "$0")/../../../web"
sh "$web/bundle.sh" "$1"
cp "$web/style.css" "$1/style.css"
