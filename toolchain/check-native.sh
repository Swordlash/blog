#!/bin/sh
# Check what the native build of wiki-server needs from the machine, before
# anything is downloaded or built.
#
#   sh toolchain/check-native.sh [--without-postgres] [--with-wizard] [--without-tex] | --help
#
# It prints one line per item, ok or missing, with how the item was found or
# what was tried, and then a summary. With --without-postgres, for a build
# of wiki-server with the cabal flag postgres off (what the deploy builds
# for a wiki in SQLite), libpq is reported as not needed and not counted.
# With --with-wizard it also checks terminfo, which the configuration
# wizard (toolchain/configure.sh) links and wiki-server does not; without
# it, terminfo is reported as not needed and not counted. It exits 0 when
# everything is there and 1 when something is missing. It installs nothing
# and changes nothing.
#
# toolchain/deploy-local.sh runs it first whenever it builds wiki-server, and
# toolchain/configure.sh with --with-wizard, before the bootstrap: before
# there is a GHC. After the Debian packages, toolchain/bootstrap.sh native
# runs the same check in Haskell (the maker's `check native`,
# maker/src/Maker/Check/Native.hs, which must say what this script says;
# toolchain/test-bootstrap.sh runs both). The deploy's move into the maker
# (docs/PLAN.md, WP5.68) retires this script.
# Without it, a missing C library shows up only as a link error deep in a
# cabal build, after the downloads and the compilers.
#
# The items, and how the build finds each one:
#
#   - the commands cc, make, curl, git and pkg-config, on PATH;
#   - GMP, which every native GHC program links with: its header gmp.h,
#     through the C compiler;
#   - libpq, for PostgreSQL: postgresql-libpq is built with its flag
#     use-pkg-config off, so its Setup runs pg_config, which must be on PATH
#     and answer pg_config --includedir. pkg-config's libpq.pc is not enough.
#     RHEL's PGDG packages put pg_config in /usr/pgsql-<NN>/bin, off PATH, so
#     when PATH has none the check looks there and in Debian's
#     /usr/lib/postgresql/<NN>/bin, and names the one it finds, to be put on
#     PATH for the deploy. WIKI_PG_CONFIG_DIRS replaces those directories (a
#     list separated by spaces), for the tests. A build without
#     PostgreSQL (--without-postgres) has no postgresql-libpq, and needs
#     no pg_config: libpq is then reported as not needed;
#   - zlib, for the zlib package, which is built without its bundled copy and
#     finds the system's zlib through pkg-config (zlib.pc);
#   - SQLite, for direct-sqlite, which cabal.project builds with its flag
#     systemlib: it compiles against the system's sqlite3.h and links
#     -lsqlite3, so the check builds a small program that way through the
#     compiler and runs it. The program asks the library it loads what
#     wiki-server asks it, and the check refuses what wiki-server refuses:
#     a version older than toolchain/pins.env's SQLITE_MIN_VERSION
#     (3.32.0), or a library built with THREADSAFE=0, OMIT_WAL,
#     OMIT_FOREIGN_KEY or a MAX_VARIABLE_NUMBER below
#     SQLITE_MIN_VARIABLE_NUMBER (32766). The line names the library's
#     version and the file it was loaded from, and sqlite3.h's version when
#     it differs. A program that builds and does not run (the library not
#     found at run time) has a line of its own. This is the library this
#     shell's loader finds: the service runs with its unit's environment,
#     and the deploy asks the built wiki-server itself in that environment
#     (wiki-server sqlite), before it stops the running server;
#   - terminfo, for the configuration wizard only (--with-wizard): vty, the
#     terminal library under brick, links GHC's terminfo package, which
#     links -ltinfo (Debian's libncurses-dev, RHEL's ncurses-devel). The
#     check links a one-line program with -ltinfo through the compiler.
#
# libsodium is not an item: the bootstrap builds the pinned release from source
# (toolchain/libsodium.sh) as a static library, which the build links into
# wiki-server, so the machine needs no libsodium to build or to run it. Its
# line says so, and is not counted.
#
# One more line, after the commands, is for information only: xelatex,
# which the server's PDF exports need and the build does not. It runs
# toolchain/check-tex.sh, which typesets a one-line document with the
# xelatex on PATH under the limits of the server's exports, for at most 20
# seconds (WIKI_TEX_TIMEOUT sets another limit). The line says ok, working
# and where it is when it works; no, failing, where it is and the first
# line of the reason when it does not; or no, not-found when PATH has no
# xelatex. The summary then says so too. It is not counted among the
# items and never makes the check fail: a wiki without PDFs is a working
# wiki. This is the PATH of the shell the check runs in; a systemd service
# has its own, which toolchain/deploy-local.sh checks again in its TeX step,
# and where it can install TeX Live under the toolchain. With --without-tex,
# which that deploy gives, nothing is typeset here: the line says that the
# deploy's TeX step checks xelatex, so that an xelatex that hangs is waited
# for once and not twice.
#
# The build sees the environment this script runs in. LIBRARY_PATH,
# C_INCLUDE_PATH, CPATH and PKG_CONFIG_PATH reach cabal untouched, so a
# library installed into a directory of one's own is checked here as the
# build will find it.
set -eu

usage() {
  printf 'usage: sh toolchain/check-native.sh [--without-postgres] [--with-wizard] [--without-tex] | --help\n'
}

postgres=yes
wizard=
tex=yes
for option do
  case $option in
    --without-postgres) postgres= ;;
    --with-wizard) wizard=yes ;;
    --without-tex) tex= ;;
    -h | --help)
      usage
      printf '\nChecks the commands and C libraries the native build of wiki-server needs\n'
      printf '(cc, make, curl, git, pkg-config, GMP, libpq, zlib, SQLite), one line each, and exits 1\n'
      printf 'when one is missing. It installs nothing. SQLite is checked by running a program\n'
      printf 'built with sqlite3.h and -lsqlite3: the library it loads, not only the header, must\n'
      printf 'be one wiki-server runs on (toolchain/pins.env: SQLITE_MIN_VERSION and the rest).\n'
      printf "That is the library this shell's loader finds; the service sees its unit's\n"
      printf "environment, not this shell's, and the deploy checks the built wiki-server there\n"
      printf 'before it stops the running one. libsodium is not needed from the system:\n'
      printf 'the bootstrap builds it from source (toolchain/libsodium.sh). It also says whether the\n'
      printf 'xelatex on PATH typesets the PDF exports (toolchain/check-tex.sh), which is not\n'
      printf 'needed for the build and never fails the check. --without-postgres\n'
      printf 'is for a build with the cabal flag postgres off, which needs no libpq.\n'
      printf '%s\n' '--with-wizard also checks terminfo, which the configuration wizard'
      printf '(toolchain/configure.sh) links. --without-tex does not check xelatex: the\n'
      printf 'deploy gives it, since its TeX step checks the TeX the service finds.\n'
      exit 0 ;;
    *)
      usage >&2
      exit 2 ;;
  esac
done

checked=0
missing=
debian=
rhel=

# Print one item's line. The arguments are the item, ok or missing, and how
# it was found or what was tried.
report() {
  checked=$((checked + 1))
  printf '%-8s %-11s %s\n' "$2" "$1" "$3"
}

# Record a missing item with its Debian and RHEL packages, for the summary.
lack() {
  missing="${missing:+$missing, }$1"
  debian="${debian:+$debian }$2"
  rhel="${rhel:+$rhel }$3"
  report "$1" missing "$4 (Debian: $2; RHEL: $3)"
}

has() { command -v "$1" >/dev/null 2>&1; }

# The commands. A command is only looked up, never run: running one is the
# build's business.
command_item() {
  if path=$(command -v "$1" 2>/dev/null); then
    report "$1" ok "$path"
  else
    lack "$1" "$2" "$3" "not on PATH"
  fi
}
command_item cc build-essential gcc
command_item make make make
command_item curl curl curl
command_item git git git
command_item pkg-config pkg-config pkgconf-pkg-config

# xelatex, for the PDF exports only, through toolchain/check-tex.sh. Its
# line is printed as the skipped lines are, so that it is not counted, and
# it never joins the missing items. tex_note keeps what the summary says
# about it, empty when it works or is not checked. With --without-tex the
# deploy's TeX step checks xelatex after this script, on the service's
# PATH, so the probe does not run here: an xelatex that hangs would
# otherwise cost its timeout twice.
tex_note=
tex_status=0
if [ -z "$tex" ]; then
  tex_status=skipped
else
  tex_report=$(sh "$(dirname "$0")/check-tex.sh" 2>&1) || tex_status=$?
  tex_first=$(printf '%s\n' "$tex_report" | sed -n '1p')
fi
case $tex_status in
  skipped)
    printf '%-8s %-11s %s\n' -- xelatex "checked by the deploy's TeX step, on the service's PATH (for the PDF exports; not counted)" ;;
  0)
    printf '%-8s %-11s %s\n' ok xelatex "working at ${tex_first#working } (for the PDF exports; not counted)" ;;
  1)
    tex_reason=$(printf '%s\n' "$tex_report" | sed -n '2p')
    printf '%-8s %-11s %s\n' no xelatex "failing at ${tex_first#failing }: ${tex_reason:-see sh toolchain/check-tex.sh} (for the PDF exports; not counted)"
    tex_note="${tex_first#failing } fails (sh toolchain/check-tex.sh says why)" ;;
  2)
    printf '%-8s %-11s %s\n' no xelatex "not-found: no xelatex on PATH (for the PDF exports; not counted)"
    tex_note="none is on PATH" ;;
  *)
    printf '%-8s %-11s %s\n' no xelatex "not checked: toolchain/check-tex.sh could not run: $tex_first (for the PDF exports; not counted)"
    tex_note="it could not be checked" ;;
esac

# GMP's header, through the C compiler's preprocessor.
if ! has cc; then
  lack GMP libgmp-dev gmp-devel "not checked: needs cc"
elif printf '#include <gmp.h>\n' | cc -E -x c - >/dev/null 2>&1; then
  report GMP ok "gmp.h, through cc -E"
else
  lack GMP libgmp-dev gmp-devel "cc -E finds no gmp.h"
fi

# libpq, through pg_config on PATH, which postgresql-libpq's Setup runs when
# cabal builds it. When PATH has no pg_config, a pg_config elsewhere is
# looked for, to name in the hint: the last one the patterns match, which is
# usually the newest PostgreSQL. A build without PostgreSQL does not have
# that package: its line says so, and is not counted among the items.
pg_config_off_path=
if [ -z "$postgres" ]; then
  printf '%-8s %-11s %s\n' skipped libpq 'not needed (built without PostgreSQL)'
elif path=$(command -v pg_config 2>/dev/null); then
  if includedir=$(pg_config --includedir 2>/dev/null) && [ -n "$includedir" ]; then
    report libpq ok "pg_config at $path, headers in $includedir"
  else
    lack libpq libpq-dev libpq-devel "pg_config at $path does not answer pg_config --includedir"
  fi
else
  # shellcheck disable=SC2086 # the directories are patterns, expanded here.
  for dir in ${WIKI_PG_CONFIG_DIRS:-/usr/pgsql-*/bin /usr/lib/postgresql/*/bin}; do
    if [ -x "$dir/pg_config" ]; then pg_config_off_path=$dir/pg_config; fi
  done
  if [ -n "$pg_config_off_path" ]; then
    lack libpq libpq-dev libpq-devel "no pg_config on PATH, but there is one at $pg_config_off_path"
  elif has pkg-config && pkg-config --exists libpq; then
    lack libpq libpq-dev libpq-devel "no pg_config on PATH, though pkg-config knows libpq: the build runs pg_config"
  else
    lack libpq libpq-dev libpq-devel "no pg_config on PATH"
  fi
fi

# zlib, through pkg-config, as the zlib package finds it.
if ! has pkg-config; then
  lack zlib zlib1g-dev zlib-devel "not checked: needs pkg-config"
elif pkg-config --exists zlib; then
  report zlib ok "pkg-config --exists zlib"
else
  lack zlib zlib1g-dev zlib-devel "pkg-config --exists zlib failed"
fi

# SQLite, as direct-sqlite links it with its flag systemlib (cabal.project):
# a program with sqlite3.h and -lsqlite3, through the C compiler, which is
# then run. The program prints what the server reads of the library it
# loads: its version, whether it is thread-safe, whether it was built
# without the write-ahead log or foreign keys, and its limit of parameters
# in one statement (sqlite3_limit on a database in memory, which starts at
# the value the library was built with). It also prints the header's
# version, and the file the library was loaded from: dladdr on the
# library's own version string, so that no ldd is needed. The floors are
# toolchain/pins.env's (SQLITE_MIN_VERSION, SQLITE_MIN_VARIABLE_NUMBER):
# the numbers wiki-server/src/Wiki/Server/Storage/SqliteLibrary.hs keeps,
# and says why. A header and a library of different versions are said even
# when both are new enough: the build and the run then find SQLite in
# different places.
sqlite_min=$(sed -n 's/^SQLITE_MIN_VERSION=//p' "$(dirname "$0")/pins.env" 2>/dev/null | head -n 1 || true)
sqlite_variables=$(sed -n 's/^SQLITE_MIN_VARIABLE_NUMBER=//p' "$(dirname "$0")/pins.env" 2>/dev/null | head -n 1 || true)
# A version's number as SQLITE_VERSION_NUMBER writes it (3.32.0 is
# 3032000); it fails for text that is not three numbers with dots between.
version_number() {
  case $1 in '' | *[!0-9.]* | *..* | .* | *.) return 1 ;; esac
  old_ifs=$IFS
  IFS=.
  # shellcheck disable=SC2086 # the version is split at its dots here.
  set -- $1
  IFS=$old_ifs
  [ $# = 3 ] || return 1
  printf '%s\n' "$(($1 * 1000000 + $2 * 1000 + $3))"
}
# Whether a text is a number of digits only.
digits() { case $1 in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }
if ! has cc; then
  lack SQLite libsqlite3-dev sqlite-devel "not checked: needs cc"
elif ! sqlite_min_number=$(version_number "$sqlite_min") || ! digits "$sqlite_variables"; then
  lack SQLite libsqlite3-dev sqlite-devel "not checked: toolchain/pins.env names no SQLITE_MIN_VERSION or SQLITE_MIN_VARIABLE_NUMBER"
else
  probe=$(mktemp -d)
  trap 'rm -rf "$probe"' EXIT
  cat >"$probe/sqlite.c" <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <sqlite3.h>
int main(void) {
  Dl_info info;
  sqlite3 *db = 0;
  int variables = -1;
  const char *version = sqlite3_libversion();
  if (sqlite3_open(":memory:", &db) == SQLITE_OK) variables = sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, -1);
  sqlite3_close(db);
  printf("header %s\n", SQLITE_VERSION);
  printf("version %s\n", version);
  printf("number %d\n", sqlite3_libversion_number());
  printf("file %s\n", dladdr((const void *)version, &info) && info.dli_fname ? info.dli_fname : "");
  printf("threadsafe %d\n", sqlite3_threadsafe());
  printf("omit_wal %d\n", sqlite3_compileoption_used("OMIT_WAL"));
  printf("omit_foreign_key %d\n", sqlite3_compileoption_used("OMIT_FOREIGN_KEY"));
  printf("max_variable_number %d\n", variables);
  return 0;
}
EOF
  if ! cc -o "$probe/sqlite" "$probe/sqlite.c" -lsqlite3 -ldl >"$probe/cc.log" 2>&1; then
    lack SQLite libsqlite3-dev sqlite-devel "cc cannot build a program with sqlite3.h and -lsqlite3"
  else
    sqlite_status=0
    "$probe/sqlite" >"$probe/out" 2>"$probe/err" || sqlite_status=$?
    field() { sed -n "s/^$1 //p" "$probe/out" | head -n 1; }
    sqlite_number=$(field number)
    if [ "$sqlite_status" != 0 ] || ! digits "$sqlite_number"; then
      # The loader's own words, without the probe's path in front.
      why=$(sed -n '1p' "$probe/err")
      why=${why#"$probe/sqlite: "}
      [ -n "$why" ] || why="it exited $sqlite_status"
      if [ "$sqlite_status" = 127 ]; then
        why="$why; the loader does not find at run time the library the build linked: give its directory in LD_LIBRARY_PATH, or put it on the loader's path (/etc/ld.so.conf.d, then ldconfig)"
      fi
      lack SQLite libsqlite3-dev sqlite-devel "a program built with sqlite3.h and -lsqlite3 does not run: $why"
    else
      sqlite_header=$(field header)
      sqlite_version=$(field version)
      sqlite_file=$(field file)
      [ -n "$sqlite_file" ] || sqlite_file='a file dladdr does not name'
      sqlite_max=$(field max_variable_number)
      if [ "$sqlite_header" = "$sqlite_version" ]; then
        seen="sqlite3.h and the library a program built with -lsqlite3 loads are $sqlite_version ($sqlite_file)"
      else
        seen="sqlite3.h is $sqlite_header and the library a program built with -lsqlite3 loads is $sqlite_version ($sqlite_file)"
      fi
      refused=', which wiki-server refuses'
      if [ "$sqlite_number" -lt "$sqlite_min_number" ]; then
        lack SQLite libsqlite3-dev sqlite-devel "$seen: wiki-server needs SQLite $sqlite_min or later"
      elif [ "$(field threadsafe)" = 0 ]; then
        lack SQLite libsqlite3-dev sqlite-devel "$seen, built with THREADSAFE=0$refused"
      elif [ "$(field omit_wal)" = 1 ]; then
        lack SQLite libsqlite3-dev sqlite-devel "$seen, built with OMIT_WAL$refused"
      elif [ "$(field omit_foreign_key)" = 1 ]; then
        lack SQLite libsqlite3-dev sqlite-devel "$seen, built with OMIT_FOREIGN_KEY$refused"
      elif digits "$sqlite_max" && [ "$sqlite_max" -lt "$sqlite_variables" ]; then
        lack SQLite libsqlite3-dev sqlite-devel "$seen, built with MAX_VARIABLE_NUMBER=$sqlite_max$refused (it needs $sqlite_variables or more)"
      elif [ "$sqlite_header" = "$sqlite_version" ]; then
        report SQLite ok "$seen; $sqlite_min or later, built as wiki-server needs"
      else
        report SQLite ok "$seen; $sqlite_min or later, built as wiki-server needs, but the two differ: the build and the run find SQLite in different places"
      fi
    fi
  fi
  rm -rf "$probe"
  trap - EXIT
fi

# libsodium is not the machine's: the bootstrap builds the release
# toolchain/pins.env pins from source (toolchain/libsodium.sh), as a static
# library in the toolchain's directory, and the build finds it there. Its
# line says so, and is not counted.
libsodium_version=$(sed -n 's/^LIBSODIUM_VERSION=//p' "$(dirname "$0")/pins.env" 2>/dev/null || true)
printf '%-8s %-11s %s\n' -- libsodium "not needed from the system: the bootstrap builds libsodium $libsodium_version from source (toolchain/libsodium.sh; not counted)"

# terminfo, linked as vty links it (GHC's terminfo package names -ltinfo).
# The probe declares the one function it calls, so that it needs no header:
# the build compiles no C against terminfo, it only links the library.
if [ -z "$wizard" ]; then
  printf '%-8s %-11s %s\n' skipped terminfo 'not needed (for the configuration wizard only: --with-wizard)'
elif ! has cc; then
  lack terminfo libncurses-dev ncurses-devel "not checked: needs cc"
else
  probe=$(mktemp -d)
  trap 'rm -rf "$probe"' EXIT
  printf 'int setupterm(const char *, int, int *);\nint main(void) { int e; (void)setupterm(0, 1, &e); return 0; }\n' >"$probe/tinfo.c"
  if cc -o "$probe/tinfo" "$probe/tinfo.c" -ltinfo >"$probe/cc.log" 2>&1; then
    report terminfo ok "-ltinfo, through cc (for the configuration wizard)"
  else
    lack terminfo libncurses-dev ncurses-devel "cc cannot link a program with -ltinfo (the configuration wizard needs it)"
  fi
  rm -rf "$probe"
  trap - EXIT
fi

what='the native build of wiki-server' needs=needs
[ -z "$wizard" ] || what="$what and the configuration wizard" needs=need
# The note on xelatex, in both summaries: without it the wiki works and
# offers no PDFs.
tex_summary() {
  [ -z "$tex_note" ] ||
    printf 'PDF exports need xelatex: %s, so the server would offer no PDFs (the deploy offers TeX Live under the toolchain: sh toolchain/deploy-local.sh --server --texlive).\n' "$tex_note"
}
if [ -z "$missing" ]; then
  printf 'All %s items %s %s are there.\n' "$checked" "$what" "$needs"
  tex_summary
  exit 0
fi

printf '\nMissing for %s: %s.\n' "$what" "$missing"
printf 'Install them and run this again:\n'
printf '    Debian, Ubuntu: sudo apt-get install %s\n' "$debian"
printf '    RHEL, Fedora:   sudo dnf install %s\n' "$rhel"
case $missing in
  *libpq*)
    printf 'postgresql-libpq runs pg_config when cabal builds it, so pg_config must be on PATH.\n'
    printf "RHEL has it in libpq-devel, or in PGDG's postgresqlNN-devel, which puts it in /usr/pgsql-NN/bin.\n"
    if [ -n "$pg_config_off_path" ]; then
      printf 'There is one at %s: put its directory on PATH for the deploy:\n' "$pg_config_off_path"
      printf "    PATH=%s:\$PATH sh toolchain/deploy-local.sh ...\n" "${pg_config_off_path%/pg_config}"
    else
      printf 'Put the directory of pg_config on PATH for the deploy:\n'
      printf "    PATH=/usr/pgsql-NN/bin:\$PATH sh toolchain/deploy-local.sh ...\n"
    fi ;;
esac
printf 'The build sees the environment this runs in: LIBRARY_PATH, C_INCLUDE_PATH, CPATH\n'
printf 'and PKG_CONFIG_PATH reach cabal untouched, for a library in a directory of its own.\n'
printf 'A shared library there also needs LD_LIBRARY_PATH when wiki-server runs\n'
printf '(toolchain/deploy-local.sh writes it into the systemd unit).\n'
tex_summary
exit 1
