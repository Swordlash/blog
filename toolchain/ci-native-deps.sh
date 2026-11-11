#!/bin/sh
# Install missing native CI packages through apt, retaining downloaded .deb
# files for actions/cache. dpkg still runs every required setup and trigger.
#
# The archive cache is $APT_ARCHIVE_DIR (default ~/.cache/wiki-apt), which
# the workflow restores before this script runs. apt takes a package from it
# when the cached file is the version the package index names, so a warm
# cache needs no download. When a download fails all the same (the mirror
# unreachable), the script installs the newest version the cache holds of
# each package apt could not fetch, without any download, and says so; on
# GitHub Actions it also writes from-cache=true to the step's outputs, so
# that the workflow does not save a cache that holds no new download. A
# download that fails while the cache holds no version of the package is
# tried once more after $APT_RETRY_PAUSE seconds (default 30), then the
# script fails, naming the package. An install that fails for any other
# reason (a package's setup, a dependency apt cannot resolve) fails at once,
# as before. apt itself already tries each download four times
# (Acquire::Retries is 3 by default since apt 2.3), so a blip of seconds
# needs nothing from here; the pause is for one of a minute.
set -eu
cd "$(dirname "$0")/.."
profile=${1:-full}
case $profile in
  base) lists=toolchain/ci-native-base-packages.txt ;;
  full) lists='toolchain/ci-native-base-packages.txt toolchain/ci-native-pdf-packages.txt' ;;
  *) printf 'usage: ci-native-deps.sh [base|full]\n' >&2; exit 2 ;;
esac
cache=${APT_ARCHIVE_DIR:-$HOME/.cache/wiki-apt}
pause=${APT_RETRY_PAUSE:-30}
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

# to_fetch <packages or archives>: the names of the packages whose archives
# apt would download to install these, one per line; nothing when the cache
# holds every one. apt's --print-uris prints one line per download, the URI
# in quotes and then the file's name in the archive directory, which starts
# with the package's name and an underscore. Fails when apt cannot resolve
# the install at all.
to_fetch() {
  # The words are package names and archive paths; splitting is intentional.
  # shellcheck disable=SC2086
  uris=$(apt_get --print-uris -qq install --yes --no-install-recommends $*) || return 1
  printf '%s\n' "$uris" | sed -n "s/^'[^']*' \([^_ ]*\)_.*/\1/p"
}

# newest_cached <package>: the path of the newest archive of the package in
# the cache, or nothing. An archive's name is <package>_<version>_<arch>.deb,
# with a version's epoch colon written %3a.
newest_cached() {
  best=
  best_version=
  for file in "$cache/$1"_*.deb; do
    [ -e "$file" ] || continue
    version=${file##*/}
    version=${version#"$1"_}
    version=$(printf '%s' "${version%_*}" | sed 's/%3[aA]/:/g')
    if [ -z "$best" ] || dpkg --compare-versions "$version" gt "$best_version"; then
      best=$file
      best_version=$version
    fi
  done
  printf '%s' "$best"
}

# from_cache: install $missing from the cache alone. Each package apt would
# download, one asked for or a dependency, is replaced by the newest archive
# of it the cache holds, given to apt by its path, until apt needs no
# download; apt then installs and configures them all with --no-download.
# When the cache cannot serve, returns 1 with the reason in $reason, before
# dpkg has touched anything. When the install itself fails, exits. apt does
# not check an archive given by its path against the index's hash, as it
# does an archive it takes from the cache by name: these are archives an
# earlier run of this workflow downloaded and apt checked then.
from_cache() {
  wanted=$missing
  rounds=0
  while :; do
    if ! fetch=$(to_fetch "$wanted"); then
      reason='apt cannot install the versions the archive cache holds'
      return 1
    fi
    [ -n "$fetch" ] || break
    rounds=$((rounds + 1))
    uncached=
    for package in $fetch; do
      file=$(newest_cached "$package")
      # A file already given to apt and still to be fetched is one apt does
      # not take; the cache has nothing else to offer for that package.
      case " $wanted " in *" $file "*) file= ;; esac
      if [ -z "$file" ] || [ "$rounds" -gt 10 ]; then
        uncached="$uncached $package"
        continue
      fi
      replaced=
      next=
      for word in $wanted; do
        if [ "$word" = "$package" ]; then
          next="$next $file"
          replaced=1
        else
          next="$next $word"
        fi
      done
      [ -n "$replaced" ] || next="$next $file"
      wanted=$next
    done
    if [ -n "$uncached" ]; then
      reason="the archive cache ($cache) holds no version of$uncached"
      return 1
    fi
  done
  printf 'Installing from the archive cache, without a download:%s\n' "$wanted"
  # shellcheck disable=SC2086
  apt_get install --yes --no-install-recommends --no-download $wanted || exit 1
}

if [ -n "$missing" ]; then
  mkdir -p "$cache"
  sudo apt-get update
  attempt=1
  # Package names come from the fixed list above; splitting is intentional.
  # shellcheck disable=SC2086
  until apt_get install --yes --no-install-recommends $missing; do
    # Only a failed download is worth another try or the cache: when apt
    # needs nothing more from the network, the install failed for another
    # reason, and apt has said which.
    needed=$(to_fetch "$missing") || exit 1
    [ -n "$needed" ] || exit 1
    # shellcheck disable=SC2086
    needed=$(printf ' %s' $needed)
    if from_cache; then
      printf 'Could not download%s: installed the versions the archive cache holds.\n' "$needed"
      if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo 'from-cache=true' >>"$GITHUB_OUTPUT"
        printf '::warning::apt could not download%s; installed from the archive cache.\n' "$needed"
      fi
      break
    fi
    if [ "$attempt" -ge 2 ]; then
      printf 'Could not download%s, and %s.\n' "$needed" "$reason" >&2
      exit 1
    fi
    printf 'Could not download%s, and %s; trying again in %s seconds.\n' \
      "$needed" "$reason" "$pause"
    sleep "$pause"
    attempt=$((attempt + 1))
  done
fi
xmllint --version
[ "$profile" = full ] || exit 0
xelatex --version >/dev/null
for file in lmodern.sty mhchem.sty tikz.sty soul.sty beamer.cls; do
  tex_file=$(kpsewhich "$file")
  [ -n "$tex_file" ] || { printf 'Missing TeX package: %s\n' "$file" >&2; exit 1; }
done
