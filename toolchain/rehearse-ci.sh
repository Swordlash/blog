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
# dropped first. With --move the wiki is in SQLite, and NEW rehearses its
# move to PostgreSQL, as `deploy-local.sh --move-to-postgres` does (WP5.80b):
# OLD serves a copy in SQLite, NEW copies it into an empty database of that
# PostgreSQL and serves it there, and each check compares what the two read. The wiki OLD makes has a space with a page and a page
# under it, written through OLD's administration listener, and the guide
# OLD installs itself, which the rehearsal leaves out of its comparison. It
# also has a space set to have no home page, as a program from before
# WP5.78 (docs/PLAN.md) allowed, which still holds the page it was made
# with: the migration gives it a home page of its own beside that page. A
# later OLD ignores the profile's homePage and keeps the space's home page,
# which the rehearsal accepts as well.
# What this script sends OLD (serve's options, POST spaces, POST
# spaces/ID/pages and PUT spaces/ID/profile) is part of what the rehearsal
# keeps stable (the README's CI section): OLD is the base branch's program,
# which this script, from the pull request, must still drive.
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
cleanup() {
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
data=$work/data
mkdir -p "$data"

if [ -n "$postgres" ]; then
  : "${WIKI_TEST_DATABASE_URL:?run toolchain/ci-postgres.sh start first}"
  base=${WIKI_TEST_DATABASE_URL%/*}
  for db in rehearsal_live rehearsal_scratch; do
    "$WIKI_TEST_PSQL" "$WIKI_TEST_DATABASE_URL" --quiet --command "DROP DATABASE IF EXISTS $db"
    "$WIKI_TEST_PSQL" "$WIKI_TEST_DATABASE_URL" --quiet --command "CREATE DATABASE $db"
  done
  set -- --database "$base/rehearsal_live" --pg-dump "$WIKI_TEST_PG_DUMP" --pg-restore "$WIKI_TEST_PG_RESTORE"
  scratch_args="--scratch-database $base/rehearsal_scratch --scratch-pg-restore $WIKI_TEST_PG_RESTORE"
elif [ -n "$move" ]; then
  : "${WIKI_TEST_DATABASE_URL:?run toolchain/ci-postgres.sh start first}"
  base=${WIKI_TEST_DATABASE_URL%/*}
  "$WIKI_TEST_PSQL" "$WIKI_TEST_DATABASE_URL" --quiet --command "DROP DATABASE IF EXISTS rehearsal_move"
  "$WIKI_TEST_PSQL" "$WIKI_TEST_DATABASE_URL" --quiet --command "CREATE DATABASE rehearsal_move"
  set -- --sqlite "$data/wiki.sqlite"
  scratch_args="--move-to-database $base/rehearsal_move"
else
  set -- --sqlite "$data/wiki.sqlite"
  scratch_args=''
fi

# OLD serves the wiki, on loopback ports this run picks.
port=$((20000 + $$ % 20000))
admin=$((port + 1))
"$old" serve --data "$data" "$@" --listen "127.0.0.1:$port" --admin-listen "127.0.0.1:$admin" >"$work/old.log" 2>&1 &
pid=$!
api=http://127.0.0.1:$admin/admin/api/v1
tries=0
until curl -fsS "$api/info" >/dev/null 2>&1; do
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
  node -e 'let s = ""; process.stdin.on("data", (d) => (s += d)); process.stdin.on("end", () => console.log(JSON.parse(s).id));'
}
space=$(post spaces '{"parent":null,"name":"Rehearsal"}' | id_of)
page=$(post "spaces/$space/pages" '{"parent":null,"title":"First page","body":"# First page\n\nA **page** of the rehearsal, with $x^2$ and a [link](https://example.org)."}' | id_of)
post "spaces/$space/pages" "{\"parent\":\"$page\",\"title\":\"A page under it\",\"body\":\"Some text under the first page.\"}" >/dev/null
homeless=$(post spaces '{"parent":null,"name":"No home page"}' | id_of)
put "spaces/$homeless/profile" '{"description":"","icon":null,"homePage":null,"blog":false,"boxNumbering":"in-page"}' >/dev/null
kill "$pid"
wait "$pid" 2>/dev/null || true
pid=''

# NEW rehearses the upgrade of that wiki. Its exit code is the result.
# shellcheck disable=SC2086
"$new" rehearse --old "$old" --data "$data" "$@" --scratch "$work/scratch" $scratch_args
