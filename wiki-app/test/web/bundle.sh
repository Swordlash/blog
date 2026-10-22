#!/bin/sh
# The islands' scripts and styles, which the browser test runner loads before
# the suite: the same bundle the application's page is served with.
set -eu
exec sh "$(dirname "$0")/../../../web/bundle.sh" "$1"
