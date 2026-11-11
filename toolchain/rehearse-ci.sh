#!/bin/sh
# The upgrade's rehearsal between two builds of wiki-server (WP5.75 of
# docs/PLAN.md, `wiki-server rehearse`), as CI runs it on every pull request:
# OLD, the base branch's build, makes a small wiki, and NEW, the pull
# request's build, rehearses the upgrade of it. The rehearsal is what a
# deploy runs before it touches the running wiki: OLD serves a copy, NEW
# migrates and serves it, and each check compares what the two read.
#
#   sh toolchain/rehearse-ci.sh OLD NEW              # on SQLite
#   sh toolchain/rehearse-ci.sh OLD NEW --postgres   # on toolchain/ci-postgres.sh's PostgreSQL
#   sh toolchain/rehearse-ci.sh NEW NEW --move       # a move from SQLite to that PostgreSQL
#
# With --postgres it reads the variables toolchain/ci-postgres.sh prints
# (WIKI_TEST_DATABASE_URL, WIKI_TEST_PG_DUMP, WIKI_TEST_PG_RESTORE,
# WIKI_TEST_PSQL), and makes two databases there, the wiki's and the copy's,
# in a namespace of the run's own, dropped when it ends. With --move the wiki is in SQLite, and NEW rehearses its
# move to PostgreSQL, as `deploy-local.sh --move-to-postgres` does (WP5.80b):
# OLD serves a copy in SQLite, NEW copies it into an empty database of that
# PostgreSQL and serves it there, and each check compares what the two read.
# The wiki OLD makes, in every mode, has a space with a page and a page
# under it, and two pages under the space's home page, one with the slug
# of the top-level page, written through OLD's administration listener, and the guide
# OLD installs itself, which the rehearsal leaves out of its comparison. It
# also has a space set to have no home page, as a program from before
# WP5.78 (docs/PLAN.md) allowed, which still holds the page it was made
# with: the migration gives it a home page of its own beside that page. A
# later OLD ignores the profile's homePage and keeps the space's home page,
# which the rehearsal accepts as well.
# What this script sends OLD (serve's options, port 0 among them, POST
# spaces, POST spaces/ID/pages and PUT spaces/ID/profile) and what it reads
# of it (the line its log has for each listener's address) is part of what
# the rehearsal keeps stable (the README's CI section): OLD is the base
# branch's program, which this script, from the pull request, must still
# drive.
set -eu
old=${1:?usage: rehearse-ci.sh OLD NEW [--postgres | --move]}
new=${2:?usage: rehearse-ci.sh OLD NEW [--postgres | --move]}
postgres='' move=''
case ${3:-} in
  --postgres) postgres=1 ;;
  --move) move=1 ;;
  '') ;;
  *) printf 'rehearse-ci: unknown option %s\n' "$3" >&2; exit 2 ;;
esac

work=$(mktemp -d)
pid=''
# The databases this run made on the PostgreSQL, dropped when it ends.
databases=''
cleanup() {
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  for db in $databases; do
    "$WIKI_TEST_PSQL" "$WIKI_TEST_DATABASE_URL" --quiet --command "DROP DATABASE IF EXISTS $db WITH (FORCE)" || true
  done
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
data=$work/data
mkdir -p "$data"

# The PostgreSQL may be shared with other runs (toolchain/ci-postgres.sh
# keeps one container for every session on a machine), so the databases
# this run makes are named in a namespace of its own, in the shape the
# server's tests use (Test.Database.namespaceFor): wiki_test_, the time the
# run began, eight random letters and digits. A run killed before its trap
# leaves them behind; the server's PostgreSQL tests drop them once they are
# six hours old.
namespace=wiki_test_$(date +%s)_$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 8)_
make_database() {
  databases="$databases $1"
  "$WIKI_TEST_PSQL" "$WIKI_TEST_DATABASE_URL" --quiet --command "CREATE DATABASE $1"
}

if [ -n "$postgres" ]; then
  : "${WIKI_TEST_DATABASE_URL:?run toolchain/ci-postgres.sh start first}"
  base=${WIKI_TEST_DATABASE_URL%/*}
  live=${namespace}rehearsal_live scratch=${namespace}rehearsal_scratch
  make_database "$live"
  make_database "$scratch"
  set -- --database "$base/$live" --pg-dump "$WIKI_TEST_PG_DUMP" --pg-restore "$WIKI_TEST_PG_RESTORE"
  scratch_args="--scratch-database $base/$scratch --scratch-pg-restore $WIKI_TEST_PG_RESTORE"
elif [ -n "$move" ]; then
  : "${WIKI_TEST_DATABASE_URL:?run toolchain/ci-postgres.sh start first}"
  base=${WIKI_TEST_DATABASE_URL%/*}
  target=${namespace}rehearsal_move
  make_database "$target"
  set -- --sqlite "$data/wiki.sqlite"
  scratch_args="--move-to-database $base/$target"
else
  set -- --sqlite "$data/wiki.sqlite"
  scratch_args=''
fi

# OLD serves the wiki on two loopback ports the system gives it
# (127.0.0.1:0), the listener's and the admin listener's, and logs each
# address it took, one line per listener:
#
#   level=info event=listening listener=admin address=http://127.0.0.1:41377/admin/ ...
#
# The script reads the admin listener's from that line. No port is chosen
# here, so two runs side by side, or a port another process holds, never
# collide. Every wiki-server since the first logs that line, so the base
# branch's does too.
"$old" serve --data "$data" "$@" --listen 127.0.0.1:0 --admin-listen 127.0.0.1:0 >"$work/old.log" 2>&1 &
pid=$!
tries=0
api=''
while :; do
  if [ -z "$api" ]; then
    admin=$(sed -n 's|.*event=listening listener=admin address="\{0,1\}\(http://[^ "]*\)/admin/"\{0,1\}\( .*\)\{0,1\}$|\1|p' "$work/old.log" | head -n 1)
    [ -z "$admin" ] || api=$admin/admin/api/v1
  fi
  if [ -n "$api" ] && curl -fsS "$api/info" >/dev/null 2>&1; then
    break
  fi
  tries=$((tries + 1))
  if [ "$tries" -gt 120 ] || ! kill -0 "$pid" 2>/dev/null; then
    cat "$work/old.log" >&2
    printf 'rehearse-ci: the old wiki-server did not answer\n' >&2
    exit 1
  fi
  sleep 0.5
done

post() {
  curl -fsS -X POST -H 'Content-Type: application/json' -H 'X-Wiki-Request: 1' --data "$2" "$api/$1"
}
put() {
  curl -fsS -X PUT -H 'Content-Type: application/json' -H 'X-Wiki-Request: 1' --data "$2" "$api/$1"
}
id_of() {
  field_of id
}
field_of() {
  node -e 'let s = ""; process.stdin.on("data", (d) => (s += d)); process.stdin.on("end", () => console.log(JSON.parse(s)[process.argv[1]]));' "$1"
}
made=$(post spaces '{"parent":null,"name":"Rehearsal"}')
space=$(printf '%s' "$made" | id_of)
home=$(printf '%s' "$made" | field_of homePage)
page=$(post "spaces/$space/pages" '{"parent":null,"title":"First page","body":"# First page\n\nA **page** of the rehearsal, with $x^2$ and a [link](https://example.org)."}' | id_of)
post "spaces/$space/pages" "{\"parent\":\"$page\",\"title\":\"A page under it\",\"body\":\"Some text under the first page.\"}" >/dev/null
# Two pages under the home page, one with the slug of the top-level page
# above: the step that makes the home page the root renames it, and the
# top-level page keeps its address. An OLD from after that step puts a
# page with no parent under the home page itself, and the rehearsal reads
# that wiki as it is.
if [ -n "$home" ] && [ "$home" != null ] && [ "$home" != undefined ]; then
  post "spaces/$space/pages" "{\"parent\":\"$home\",\"title\":\"First page\",\"body\":\"A page under the home page, with the slug of a top-level page.\"}" >/dev/null
  post "spaces/$space/pages" "{\"parent\":\"$home\",\"title\":\"Under the home page\",\"body\":\"Some text under the home page.\"}" >/dev/null
fi
homeless=$(post spaces '{"parent":null,"name":"No home page"}' | id_of)
put "spaces/$homeless/profile" '{"description":"","icon":null,"homePage":null,"blog":false,"boxNumbering":"in-page"}' >/dev/null
kill "$pid"
wait "$pid" 2>/dev/null || true
pid=''

# NEW rehearses the upgrade of that wiki. Its exit code is the result.
# shellcheck disable=SC2086
"$new" rehearse --old "$old" --data "$data" "$@" --scratch "$work/scratch" $scratch_args
