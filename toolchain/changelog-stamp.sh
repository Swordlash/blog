#!/bin/sh
# Write wiki-server/changelog.stamp, the file that makes cabal rebuild
# wiki-server when the page "What's new?" it embeds would change.
#
#   sh toolchain/changelog-stamp.sh
#
# wiki-server reads the changelog's entries and its version when it is
# compiled (wiki-server/src/Wiki/Server/WhatsNew.hs). cabal rebuilds a
# package when a file its extra-source-files matched at the last build
# changes, but not when a glob matches a new file: an entry added would
# not rebuild the server. So the stamp, which extra-source-files lists,
# holds the names of the entries, and the version when the environment
# gives one (WIKI_BUILD_VERSION: CI and the deploy set it): a new entry,
# or a new version, changes the stamp, and cabal rebuilds the server, whose
# module of the page is compiled on every build of the package. Without
# WIKI_BUILD_VERSION, as in a build by hand, the version is what git
# describe says when the server is next compiled for another reason.
#
# The builds that go through toolchain/npm-command.sh, the deploy, the
# smoke test and the Docker image run it before cabal. The stamp is not in
# git (.gitignore). It is rewritten only when its content changes.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# A copy of the scripts without the packages (the deploy's tests) has no
# server to stamp.
[ -d "$ROOT/wiki-server" ] || exit 0
stamp=$ROOT/wiki-server/changelog.stamp
new=$stamp.new
{
  printf '# Written by toolchain/changelog-stamp.sh: what makes cabal rebuild wiki-server.\n'
  printf 'version=%s\n' "${WIKI_BUILD_VERSION:-}"
  for entry in "$ROOT"/changelog/*.md; do
    [ -e "$entry" ] || continue
    printf 'entry=%s\n' "${entry##*/}"
  done
} >"$new"
if cmp -s "$new" "$stamp"; then rm -f "$new"; else mv "$new" "$stamp"; fi
