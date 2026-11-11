#!/bin/sh
# Regression tests of toolchain/ci-native-deps.sh, against a fake apt-get
# whose downloads can be made to fail, as when GitHub's runners cannot
# reach their Ubuntu mirror: the install when the download works (nothing
# changes from before), when the cache holds the very version the index
# names, when it holds only older versions (the newest of them is installed
# by its path, a dependency's as well, and the step's outputs say
# from-cache=true), when it holds no version of a package (one more try
# after a pause, then a failure naming the package), when the download
# fails once and works the second time, and when the install fails for a
# reason other than a download (no second try, no cache).
#
#   sh toolchain/test-ci-native-deps.sh
#
# Needs neither root nor the network: sudo, apt-get, dpkg-query, xmllint
# and sleep are fakes on the PATH the script under test sees first, and
# apt's archive directory is a temporary one. The real dpkg compares
# versions. The base profile is tested, with the real package list.
set -eu
cd "$(dirname "$0")/.."
script=$(pwd)/toolchain/ci-native-deps.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
mkdir -p "$work/bin"

# The fake apt-get. $FAKE/index is the package index, a line per package:
# its name, its version and the packages it depends on, joined by commas.
# $FAKE/status lists what is installed, a name and a version per line.
# install resolves the packages asked for (names, or archives by their
# path) and the dependencies not installed, then, as apt does: with
# --print-uris it prints a line per archive the archive directory lacks
# (quoted URI, file name, size, hash) and stops; without, an archive it
# lacks is downloaded into it, unless $FAKE/downloads-fail or
# $FAKE/downloads-fail-once (removed when used) exists or --no-download is
# given, which fail with exit 100 before anything is installed; then dpkg
# installs everything, unless $FAKE/dpkg-fails exists. update succeeds,
# with apt's warning when downloads fail, as on the runners. Each call is
# logged, one per line, and each package installed, with where from.
cat >"$work/bin/apt-get" <<'FAKE'
#!/bin/sh
printf 'apt-get %s\n' "$*" >>"$FAKE/calls"
archives= print_uris= no_download= command= words=
while [ $# -gt 0 ]; do
  case $1 in
    -o) case $2 in Dir::Cache::archives=*) archives=${2#*=} ;; esac; shift ;;
    --print-uris) print_uris=1 ;;
    --no-download) no_download=1 ;;
    -*) ;;
    update|install) command=$1 ;;
    *) words="$words $1" ;;
  esac
  shift
done
if [ "$command" = update ]; then
  if [ -e "$FAKE/downloads-fail" ] || [ -e "$FAKE/downloads-fail-once" ]; then
    echo "W: Failed to fetch mirror+file:/etc/apt/apt-mirrors.txt/dists/noble/InRelease  Temporary failure resolving 'azure.archive.ubuntu.com'"
    echo 'W: Some index files failed to download. They have been ignored, or old ones used instead.'
  fi
  exit 0
fi
[ "$command" = install ] && [ -n "$archives" ] || { echo 'fake apt-get: unexpected call' >&2; exit 2; }
installed() { grep -q "^$1 " "$FAKE/status"; }
# selected: a line per package, "name version file explicit".
: >"$FAKE/selected"
# select_ <name> [version file explicit]: selects the package, unless it is
# selected already, and resolves its dependencies. Without a version, the
# package is an archive given by its path, selected already.
select_() {
  if [ $# -gt 1 ]; then
    ! grep -q "^$1 " "$FAKE/selected" || return 0
    printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >>"$FAKE/selected"
  fi
  deps=$(awk -v n="$1" '$1 == n { print $3 }' "$FAKE/index" | tr ',' ' ')
  for dep in $deps; do
    installed "$dep" || resolve "$dep"
  done
}
resolve() {
  line=$(awk -v n="$1" '$1 == n' "$FAKE/index")
  [ -n "$line" ] || { echo "E: Unable to locate package $1"; exit 100; }
  set -- $line
  select_ "$1" "$2" "$1_$(printf '%s' "$2" | sed 's/:/%3a/g')_amd64.deb" no
}
# An archive given by its path is that package's candidate, whatever the
# index says: the archives first, then the names.
for word in $words; do
  case $word in
    /*)
      base=${word##*/}
      version=${base#*_}
      printf '%s %s %s yes\n' "${base%%_*}" \
        "$(printf '%s' "${version%_*}" | sed 's/%3a/:/g')" "$base" >>"$FAKE/selected"
      ;;
  esac
done
for word in $words; do
  case $word in
    /*) base=${word##*/}; select_ "${base%%_*}" ;;
    *) resolve "$word" ;;
  esac
done
lacking=$(awk -v d="$archives" '$4 == "no" { print $3 }' "$FAKE/selected" | while read -r file; do
  [ -e "$archives/$file" ] || printf '%s\n' "$file"
done)
if [ -n "$print_uris" ]; then
  for file in $lacking; do
    printf "'http://azure.archive.ubuntu.com/ubuntu/pool/main/%s' %s 39384 SHA512:0\n" "$file" "$file"
  done
  exit 0
fi
if [ -n "$lacking" ]; then
  if [ -n "$no_download" ]; then
    echo 'E: Unable to fetch some archives, maybe run apt-get update or try with --fix-missing?'
    exit 100
  fi
  if [ -e "$FAKE/downloads-fail-once" ]; then
    rm "$FAKE/downloads-fail-once"
    failing=1
  else
    failing=
  fi
  if [ -n "$failing" ] || [ -e "$FAKE/downloads-fail" ]; then
    for file in $lacking; do
      echo "E: Failed to fetch mirror+file:/etc/apt/apt-mirrors.txt/pool/main/$file  Temporary failure resolving 'azure.archive.ubuntu.com'"
    done
    echo 'E: Unable to fetch some archives, maybe run apt-get update or try with --fix-missing?'
    exit 100
  fi
  for file in $lacking; do
    echo downloaded >"$archives/$file"
    printf 'download %s\n' "$file" >>"$FAKE/calls"
  done
fi
if [ -e "$FAKE/dpkg-fails" ]; then
  echo 'E: Sub-process /usr/bin/dpkg returned an error code (1)'
  exit 100
fi
while read -r name version file explicit; do
  printf '%s %s\n' "$name" "$version" >>"$FAKE/status"
  printf 'installed %s %s from %s\n' "$name" "$version" "$file" >>"$FAKE/calls"
done <"$FAKE/selected"
FAKE

cat >"$work/bin/dpkg-query" <<'FAKE'
#!/bin/sh
for package; do :; done
if grep -q "^$package " "$FAKE/status"; then
  printf 'install ok installed'
else
  echo "dpkg-query: no packages found matching $package" >&2
  exit 1
fi
FAKE

cat >"$work/bin/sudo" <<'FAKE'
#!/bin/sh
exec "$@"
FAKE

cat >"$work/bin/sleep" <<'FAKE'
#!/bin/sh
printf 'sleep %s\n' "$*" >>"$FAKE/calls"
FAKE

cat >"$work/bin/xmllint" <<'FAKE'
#!/bin/sh
echo 'xmllint: using libxml version 20914'
FAKE
chmod 755 "$work/bin/apt-get" "$work/bin/dpkg-query" "$work/bin/sudo" \
  "$work/bin/sleep" "$work/bin/xmllint"

# The index the cases share: libxml2-utils, the one package of the base
# list a runner lacks, depends on libxml2 (installed) and on libxmlextra1
# (not installed, and with an epoch, as apt writes it in an archive's name).
index='libxml2-utils 2.9.14+dfsg-1.3ubuntu3.10 libxml2,libxmlextra1
libxmlextra1 1:1.1
libxml2 2.9.14+dfsg-1.3ubuntu3.10
libpq-dev 16.15-0ubuntu0.24.04.1
libncurses-dev 6.4+20240113-1ubuntu2.2
'
on_image='libpq-dev 16.15-0ubuntu0.24.04.1
libncurses-dev 6.4+20240113-1ubuntu2.2
libxml2 2.9.14+dfsg-1.3ubuntu3.10
'
current='libxml2-utils_2.9.14+dfsg-1.3ubuntu3.10_amd64.deb libxmlextra1_1%3a1.1_amd64.deb'
older='libxml2-utils_2.9.14+dfsg-1.3ubuntu3_amd64.deb libxml2-utils_2.9.14+dfsg-1.3ubuntu3.9_amd64.deb libxmlextra1_1%3a1.0_amd64.deb'

# case_ <name> <cached archives> [flag files]: runs the script's base
# profile with the index, the image's packages installed, the archives in
# the cache and the flags (downloads-fail, downloads-fail-once, dpkg-fails)
# set. Leaves the output in $work/out, the exit status in $status, the
# fake's log in $work/fake/calls and the step's outputs in $work/output.
case_() {
  name=$1
  rm -rf "$work/fake" "$work/cache"
  mkdir -p "$work/fake" "$work/cache"
  printf '%s' "$index" >"$work/fake/index"
  printf '%s' "${status_lines-$on_image}" >"$work/fake/status"
  for file in $2; do echo cached >"$work/cache/$file"; done
  shift 2
  for flag; do touch "$work/fake/$flag"; done
  : >"$work/fake/calls"
  : >"$work/output"
  status=0
  PATH="$work/bin:$PATH" FAKE="$work/fake" APT_ARCHIVE_DIR="$work/cache" \
    GITHUB_OUTPUT="$work/output" APT_RETRY_PAUSE=7 \
    sh "$script" base >"$work/out" 2>&1 || status=$?
}

fail() {
  echo "FAIL $name: $1"
  sed 's/^/  out: /' "$work/out"
  sed 's/^/  log: /' "$work/fake/calls"
  failures=$((failures + 1))
}

# expect_status <ok|fails>: how the script ended.
expect_status() {
  case $1 in
    ok) [ "$status" -eq 0 ] || { fail "exited $status, expected success"; return; } ;;
    fails) [ "$status" -ne 0 ] || { fail 'succeeded, expected a failure'; return; } ;;
  esac
  echo "ok   $name: $1"
}

# expect_log <what> <grep -c pattern> <count>: the fake's log has that many
# lines matching.
expect_log() {
  got=$(grep -c -e "$2" "$work/fake/calls" || true)
  if [ "$got" -eq "$3" ]; then
    echo "ok   $name: $1"
  else
    fail "$1: $got lines match \"$2\", expected $3"
  fi
}

# expect_output <what> <text>: the script's output contains the text.
expect_output() {
  if grep -q -F -e "$2" "$work/out"; then
    echo "ok   $name: $1"
  else
    fail "$1: no \"$2\" in the output"
  fi
}

# expect_from_cache <true|unset>: what the step's outputs say.
expect_from_cache() {
  if [ "$1" = true ]; then
    grep -q -x 'from-cache=true' "$work/output" || { fail 'no from-cache=true in the outputs'; return; }
  else
    [ ! -s "$work/output" ] || { fail "outputs: $(cat "$work/output")"; return; }
  fi
  echo "ok   $name: from-cache $1"
}

status_lines="${on_image}libxml2-utils 2.9.14+dfsg-1.3ubuntu3.10
"
case_ 'nothing missing' ''
unset status_lines
expect_status ok
expect_log 'no apt-get at all' '^apt-get' 0

case_ 'the download works' ''
expect_status ok
expect_log 'one update' '^apt-get update' 1
expect_log 'one install' 'Packages=true install' 1
expect_log 'both archives downloaded' '^download ' 2
expect_log 'the index version installed' '^installed libxml2-utils 2.9.14+dfsg-1.3ubuntu3.10 from libxml2-utils_' 1
expect_log 'its dependency too' '^installed libxmlextra1 1:1.1 from' 1
expect_log 'no pause' '^sleep' 0
expect_from_cache unset
for file in $current; do
  [ -e "$work/cache/$file" ] || fail "$file is not kept in the cache"
done

case_ 'the cache holds the index version' "$current" downloads-fail
expect_status ok
expect_log 'one install, no download' 'Packages=true install' 1
expect_log 'the index version installed' '^installed libxml2-utils 2.9.14+dfsg-1.3ubuntu3.10 from libxml2-utils_' 1
expect_from_cache unset

case_ 'the cache holds older versions' "$older" downloads-fail
expect_status ok
expect_log 'the newest cached version, by its path' "^installed libxml2-utils 2.9.14+dfsg-1.3ubuntu3.9 from libxml2-utils_2.9.14+dfsg-1.3ubuntu3.9_amd64.deb" 1
expect_log "the dependency's cached version" '^installed libxmlextra1 1:1.0 from libxmlextra1_1%3a1.0_amd64.deb' 1
expect_log 'installed without a download' "^apt-get .*--no-download .*$work/cache/libxml2-utils_2.9.14+dfsg-1.3ubuntu3.9_amd64.deb" 1
expect_log 'no pause' '^sleep' 0
expect_output 'and it says so' 'Could not download libxml2-utils libxmlextra1: installed the versions the archive cache holds.'
expect_from_cache true
if [ "$(ls "$work/cache" | wc -l)" -ne 3 ]; then
  fail "the cache changed: $(ls "$work/cache")"
fi

case_ 'the cache lacks a dependency' 'libxml2-utils_2.9.14+dfsg-1.3ubuntu3.9_amd64.deb' downloads-fail
expect_status fails
expect_log 'one pause, then one more try' '^sleep 7$' 1
expect_log 'two installs that download' 'Packages=true install --yes --no-install-recommends libxml2-utils' 2
expect_log 'nothing installed' '^installed' 0
expect_output 'and it names the package' "Could not download libxml2-utils libxmlextra1, and the archive cache ($work/cache) holds no version of libxmlextra1."
expect_from_cache unset

case_ 'the cache is empty' '' downloads-fail
expect_status fails
expect_log 'nothing installed' '^installed' 0
expect_output 'and it names the packages' "holds no version of libxml2-utils libxmlextra1."

case_ 'the download fails once' '' downloads-fail-once
expect_status ok
expect_log 'one pause' '^sleep 7$' 1
expect_log 'the index version installed' '^installed libxml2-utils 2.9.14+dfsg-1.3ubuntu3.10 from libxml2-utils_' 1
expect_output 'and it says why it waits' 'trying again in 7 seconds'
expect_from_cache unset

case_ 'dpkg fails' "$current" dpkg-fails
expect_status fails
expect_log 'no second try' 'Packages=true install' 1
expect_log 'no pause' '^sleep' 0
expect_log 'no install from the cache' '--no-download' 0
expect_from_cache unset

if [ "$failures" -gt 0 ]; then
  echo "$failures failures"
  exit 1
fi
echo "all passed"
