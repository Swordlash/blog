#!/bin/sh
# Install missing native CI packages through apt, retaining downloaded .deb
# files for actions/cache. dpkg still runs every required setup and trigger.
set -eu
cd "$(dirname "$0")/.."
cache=${APT_ARCHIVE_DIR:-$HOME/.cache/wiki-apt}
missing=
while IFS= read -r package; do
  [ -n "$package" ] || continue
  status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
  if [ "$status" != 'install ok installed' ]; then
    missing="$missing $package"
  fi
done < toolchain/ci-native-packages.txt
if [ -n "$missing" ]; then
  mkdir -p "$cache"
  sudo apt-get update
  # Package names come from the fixed list above; splitting is intentional.
  # shellcheck disable=SC2086
  sudo env DEBIAN_FRONTEND=noninteractive apt-get \
    -o "Dir::Cache::archives=$cache/" \
    -o APT::Keep-Downloaded-Packages=true \
    -o Binary::apt-get::APT::Keep-Downloaded-Packages=true \
    install --yes --no-install-recommends $missing
fi
xmllint --version
xelatex --version >/dev/null
for file in lmodern.sty mhchem.sty tikz.sty soul.sty beamer.cls; do
  tex_file=$(kpsewhich "$file")
  [ -n "$tex_file" ] || { printf 'Missing TeX package: %s\n' "$file" >&2; exit 1; }
done
