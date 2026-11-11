#!/bin/sh
# Regression tests of toolchain/ci-native-deps.sh, against a fake apt-get:
# nothing to install; the archive cache holds every archive the index
# names (no apt-get update at all, one install with --no-download);
# something must be downloaded (apt is asked first, then the update runs,
# bounded, then the install); the update fails or hangs (the install goes
# on); the download fails, as when GitHub's runners cannot reach their
# Ubuntu mirror (the script fails with apt's message, and nothing is
# installed from anywhere else); and dpkg fails.
#
#   sh toolchain/test-ci-native-deps.sh
#
# Needs neither root nor the network: sudo, apt-get, dpkg-query and xmllint
# are fakes on the PATH the script under test sees first, and apt's archive
# directory is a temporary one. The base profile is tested, with the real
# package list.
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
# install selects the packages asked for and the dependencies not
# installed, then, as apt does: with --print-uris it prints a line per
# archive the archive directory lacks (quoted URI, file name, size, hash)
# and stops; without, an archive it lacks is downloaded into it, unless
# $FAKE/downloads-fail exists or --no-download is given, which fail with
# exit 100 before anything is installed; then dpkg installs everything,
# unless $FAKE/dpkg-fails exists. update succeeds, with apt's warning when
# downloads fail, as on the runners, fails when $FAKE/update-fails exists
# and hangs for half a minute when $FAKE/update-hangs does. Each call is
# logged, one per line, and each package installed.
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
  if [ -e "$FAKE/downloads-fail" ]; then
    echo "W: Failed to fetch mirror+file:/etc/apt/apt-mirrors.txt/dists/noble/InRelease  Temporary failure resolving 'azure.archive.ubuntu.com'"
    echo 'W: Some index files failed to download. They have been ignored, or old ones used instead.'
  fi
  if [ -e "$FAKE/update-fails" ]; then
    echo 'E: The repository is not signed.'
    exit 100
  fi
  [ ! -e "$FAKE/update-hangs" ] || exec /bin/sleep 30
  exit 0
fi
[ "$command" = install ] && [ -n "$archives" ] || { echo 'fake apt-get: unexpected call' >&2; exit 2; }
# selected: a line per package, "name version file".
: >"$FAKE/selected"
select_() {
  ! grep -q "^$1 " "$FAKE/selected" || return 0
  line=$(awk -v n="$1" '$1 == n' "$FAKE/index")
  [ -n "$line" ] || { echo "E: Unable to locate package $1"; exit 100; }
  set -- $line
  printf '%s %s %s_%s_amd64.deb\n' "$1" "$2" "$1" "$2" >>"$FAKE/selected"
  for dep in $(printf '%s' "${3:-}" | tr ',' ' '); do
    grep -q "^$dep " "$FAKE/status" || select_ "$dep"
  done
}
for word in $words; do select_ "$word"; done
lacking=$(awk '{ print $3 }' "$FAKE/selected" | while read -r file; do
  [ -e "$archives/$file" ] || printf '%s\n' "$file"
done)
if [ -n "$print_uris" ]; then
  for file in $lacking; do
    printf "'http://azure.archive.ubuntu.com/ubuntu/pool/main/%s' %s 39384 SHA512:0\n" "$file" "$file"
  done
  exit 0
fi
if [ -n "$lacking" ]; then
  if [ -n "$no_download" ] || [ -e "$FAKE/downloads-fail" ]; then
    [ -n "$no_download" ] || for file in $lacking; do
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
while read -r name version file; do
  printf '%s %s\n' "$name" "$version" >>"$FAKE/status"
  printf 'installed %s %s\n' "$name" "$version" >>"$FAKE/calls"
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

cat >"$work/bin/xmllint" <<'FAKE'
#!/bin/sh
echo 'xmllint: using libxml version 20914'
FAKE
chmod 755 "$work/bin/apt-get" "$work/bin/dpkg-query" "$work/bin/sudo" \
  "$work/bin/xmllint"

# The index the cases share: libxml2-utils, the one package of the base
# list a runner lacks, depends on libxml2 (installed) and on libxmlextra1
# (not installed).
index='libxml2-utils 2.9.14+dfsg-1.3ubuntu3.10 libxml2,libxmlextra1
libxmlextra1 1.1
libxml2 2.9.14+dfsg-1.3ubuntu3.10
libpq-dev 16.15-0ubuntu0.24.04.1
libncurses-dev 6.4+20240113-1ubuntu2.2
'
on_image='libpq-dev 16.15-0ubuntu0.24.04.1
libncurses-dev 6.4+20240113-1ubuntu2.2
libxml2 2.9.14+dfsg-1.3ubuntu3.10
'
current='libxml2-utils_2.9.14+dfsg-1.3ubuntu3.10_amd64.deb libxmlextra1_1.1_amd64.deb'

# case_ <name> <cached archives> [flag files]: runs the script's base
# profile with the index, the image's packages installed, the archives in
# the cache and the flags (downloads-fail, dpkg-fails, update-fails,
# update-hangs) set; $status_lines, when set, replaces the image's
# packages, and $update_limit is the script's APT_UPDATE_LIMIT (default
# 45). Leaves the output in $work/out, the exit status in $status and the
# fake's log in $work/fake/calls.
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
  status=0
  PATH="$work/bin:$PATH" FAKE="$work/fake" APT_ARCHIVE_DIR="$work/cache" \
    APT_UPDATE_LIMIT="${update_limit:-45}" \
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

# expect_log <what> <grep pattern> <count>: the fake's log has that many
# lines matching.
expect_log() {
  got=$(grep -c -e "$2" "$work/fake/calls" || true)
  if [ "$got" -eq "$3" ]; then
    echo "ok   $name: $1"
  else
    fail "$1: $got lines match \"$2\", expected $3"
  fi
}

# expect_before <what> <pattern> <later pattern>: the fake's log has a line
# matching the first pattern before any line matching the second.
expect_before() {
  first=$(grep -n -e "$2" "$work/fake/calls" | head -n 1 | cut -d: -f1)
  later=$(grep -n -e "$3" "$work/fake/calls" | head -n 1 | cut -d: -f1)
  if [ -n "$first" ] && [ -n "$later" ] && [ "$first" -lt "$later" ]; then
    echo "ok   $name: $1"
  else
    fail "$1: \"$2\" at line ${first:-none}, \"$3\" at line ${later:-none}"
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

update='^apt-get -o Acquire::Retries=0 update$'
install='Packages=true install --yes --no-install-recommends libxml2-utils$'
install_cached='Packages=true install --yes --no-install-recommends --no-download libxml2-utils$'

status_lines="${on_image}libxml2-utils 2.9.14+dfsg-1.3ubuntu3.10
"
case_ 'nothing missing' ''
unset status_lines
expect_status ok
expect_log 'no apt-get at all' '^apt-get' 0

case_ 'the cache serves everything' "$current" downloads-fail
expect_status ok
expect_log 'no update at all' 'update$' 0
expect_log 'one install, with --no-download' "$install_cached" 1
expect_log 'no other install' 'Packages=true install' 1
expect_log 'no download' '^download ' 0
expect_log 'the package installed' '^installed libxml2-utils ' 1
expect_log 'its dependency too' '^installed libxmlextra1 ' 1
expect_output 'and it says so' 'installing without an update or a download'

case_ 'something must be downloaded' ''
expect_status ok
expect_before 'apt is asked first' '--print-uris' "$update"
expect_log 'one update, bounded' "$update" 1
expect_log 'no other update' 'update$' 1
expect_before 'then the install' "$update" "$install"
expect_log 'one install' 'Packages=true install' 1
expect_log 'both archives downloaded' '^download ' 2
expect_log 'the package installed' '^installed libxml2-utils ' 1
for file in $current; do
  [ -e "$work/cache/$file" ] || fail "$file is not kept in the cache"
done

case_ 'the update fails' '' update-fails
expect_status ok
expect_output 'and it says so' 'apt-get update failed'
expect_log 'the install goes on' '^installed libxml2-utils ' 1

update_limit=1
case_ 'the update hangs' '' update-hangs
unset update_limit
expect_status ok
expect_output 'it is stopped, and it says so' 'apt-get update failed or took more than 1 seconds'
expect_log 'the install goes on' '^installed libxml2-utils ' 1

case_ 'the download fails' 'libxml2-utils_2.9.14+dfsg-1.3ubuntu3_amd64.deb' downloads-fail
expect_status fails
expect_output "with apt's message" 'E: Unable to fetch some archives'
expect_log 'one install, no second try' 'Packages=true install' 1
expect_log 'nothing from the cache by --no-download' '--no-download' 0
expect_log 'nothing installed' '^installed' 0

case_ 'dpkg fails after a download' '' dpkg-fails
expect_status fails
expect_log 'one install' 'Packages=true install' 1
expect_log 'nothing installed' '^installed' 0

case_ 'dpkg fails on what the cache holds' "$current" dpkg-fails
expect_status fails
expect_log 'no update' 'update$' 0
expect_log 'one install' 'Packages=true install' 1
expect_log 'nothing installed' '^installed' 0

if [ "$failures" -gt 0 ]; then
  echo "$failures failures"
  exit 1
fi
echo "all passed"
