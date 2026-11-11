#!/bin/sh
# Install missing native CI packages through apt, retaining downloaded .deb
# files for actions/cache. dpkg still runs every required setup and trigger.
#
# The archive cache is $APT_ARCHIVE_DIR (default ~/.cache/wiki-apt), which
# the workflow restores before this script runs. apt takes a package from it
# when the cached file is the version the package index names, so a warm
# cache needs no download.
#
# The script first asks apt what it would download against the package
# index the runner image came with, before any apt-get update. When that is
# nothing, it installs at once, with no update and no network. This is
# sound: the cache's key carries the image's version, so on an exact hit
# the archives are those the image's index names, and apt still checks
# each one against that index's hashes. An index a week old only matters
# when something has to be downloaded, and then the update runs. It runs
# bounded (no retries, $APT_UPDATE_LIMIT seconds in all, default 45; a
# healthy one takes about five), because apt waits on a name that does not
# resolve for as long as the resolver does. An update that fails or is
# stopped leaves the index the machine has, and the install goes on.
#
# When the mirror cannot be reached and the cache lacks a version the index
# names, the install fails, as it always has: there is no fallback to older
# cached versions, since installing those means resolving dependencies by
# hand against apt. apt itself retries a failed download (Acquire::Retries,
# 3 by default since apt 2.3.2).
set -eu
cd "$(dirname "$0")/.."
profile=${1:-full}
case $profile in
  base) lists=toolchain/ci-native-base-packages.txt ;;
  full) lists='toolchain/ci-native-base-packages.txt toolchain/ci-native-pdf-packages.txt' ;;
  *) printf 'usage: ci-native-deps.sh [base|full]\n' >&2; exit 2 ;;
esac
cache=${APT_ARCHIVE_DIR:-$HOME/.cache/wiki-apt}
update_limit=${APT_UPDATE_LIMIT:-45}
missing=
for list in $lists; do
  while IFS= read -r package; do
    [ -n "$package" ] || continue
    status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
    if [ "$status" != 'install ok installed' ]; then
      missing="$missing $package"
    fi
  done < "$list"
done

# apt_get <arguments>: apt-get as root, with the archive cache as apt's
# archive directory and the downloaded files kept there.
apt_get() {
  sudo env DEBIAN_FRONTEND=noninteractive apt-get \
    -o "Dir::Cache::archives=$cache/" \
    -o APT::Keep-Downloaded-Packages=true \
    -o Binary::apt-get::APT::Keep-Downloaded-Packages=true \
    "$@"
}

if [ -n "$missing" ]; then
  mkdir -p "$cache"
  # What apt would download, against the index the image came with: one
  # line per archive, which --print-uris prints starting with the quoted
  # URI. Empty when the cache holds every one.
  # Package names come from the fixed list above; splitting is intentional.
  # shellcheck disable=SC2086
  if uris=$(apt_get --print-uris -qq install --yes --no-install-recommends $missing 2>/dev/null) &&
    ! printf '%s\n' "$uris" | grep -q "^'"; then
    echo 'The archive cache holds every archive the index names: installing without an update or a download.'
    # shellcheck disable=SC2086
    apt_get install --yes --no-install-recommends --no-download $missing
  else
    sudo timeout "$update_limit" apt-get -o Acquire::Retries=0 update ||
      echo "apt-get update failed or took more than $update_limit seconds; going on with the package index the machine has."
    # shellcheck disable=SC2086
    apt_get install --yes --no-install-recommends $missing
  fi
fi
xmllint --version
[ "$profile" = full ] || exit 0
xelatex --version >/dev/null
for file in lmodern.sty mhchem.sty tikz.sty soul.sty beamer.cls; do
  tex_file=$(kpsewhich "$file")
  [ -n "$tex_file" ] || { printf 'Missing TeX package: %s\n' "$file" >&2; exit 1; }
done
