#!/bin/sh
# Tests of toolchain/ci-postgres.sh, against real containers of names of the
# test's own: `start` twice in a row gives the same container and port, and
# leaves a query in flight alone; `env` prints the variables of a running
# container and starts nothing; the pg_dump and psql it writes reach the
# container's PostgreSQL through the host's address; a host port another
# process holds does not stop a second container from starting beside the
# first; a stopped container is made again, as `restart` always does; two
# starts at once make one container; and a
# container made by the script's earlier version, with PostgreSQL on another
# port inside, is read as it is.
#
#   sh toolchain/test-ci-postgres.sh
#
# It needs Docker and pulls postgres:17 if it is missing. Without Docker it
# says it did not run and fails. It removes only the containers it made.
set -eu
cd "$(dirname "$0")/.."
script=$(pwd)/toolchain/ci-postgres.sh

if ! docker info >/dev/null 2>&1; then
  printf 'not run: Docker does not answer here\n' >&2
  exit 1
fi

work=$(mktemp -d)
prefix=wiki-ci-postgres-test-$(basename "$work" | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z')
holder=''
cleanup() {
  [ -z "$holder" ] || kill "$holder" 2>/dev/null || true
  for suffix in first second twin legacy absent; do
    docker rm -f "$prefix-$suffix" >/dev/null 2>&1 || true
  done
  rm -rf "$work"
}
trap cleanup EXIT
failures=0

pass() { printf 'ok: %s\n' "$1"; }
fail() {
  printf 'FAILED: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Run the script for the container NAME's suffix, with a directory of its
# own for the programs it writes; its output goes to $work/<suffix>.out.
ci_postgres() {
  WIKI_CI_POSTGRES_NAME=$prefix-$2 sh "$script" "$1" "$work/bin-$2" >"$work/$2.out" 2>"$work/$2.err"
}
# A variable the script printed for that suffix.
variable() { sed -n "s/^$2=//p" "$work/$1.out"; }
port_of() { variable "$1" WIKI_TEST_DATABASE_URL | sed -n 's|^postgres://wiki@127\.0\.0\.1:\([0-9]*\)/postgres$|\1|p'; }
id_of() { docker inspect --format '{{.Id}}' "$prefix-$1" 2>/dev/null || true; }
# A query through the psql the script wrote, on the URL it printed.
query() { "$(variable "$1" WIKI_TEST_PSQL)" "$(variable "$1" WIKI_TEST_DATABASE_URL)" -tA -c "$2"; }
# Whether something on the host accepts a connection on that port.
open() {
  node -e '
    const s = require("node:net").connect(Number(process.argv[1]), "127.0.0.1");
    s.on("connect", () => process.exit(0));
    s.on("error", () => process.exit(1));
  ' "$1"
}

# The first start: four variables, a port on the host, and programs that
# reach PostgreSQL.
if ci_postgres start first && [ "$(wc -l <"$work/first.out")" -eq 4 ] && [ -n "$(port_of first)" ] \
  && open "$(port_of first)" && [ "$(query first 'SELECT 1')" = 1 ]; then
  pass 'start makes a container on a port Docker chooses, and psql reaches it through the address printed'
else
  fail 'the first start'
  cat "$work/first.out" "$work/first.err" >&2
fi
first_port=$(port_of first)
first_id=$(id_of first)

# pg_dump and pg_restore are given the database as --dbname=URL, as the
# server gives it.
query first 'CREATE DATABASE kept' >/dev/null
query first 'SELECT 1' >/dev/null
"$(variable first WIKI_TEST_PSQL)" "postgres://wiki@127.0.0.1:$first_port/kept" -q -c 'CREATE TABLE t (x int); INSERT INTO t VALUES (42)'
if "$(variable first WIKI_TEST_PG_DUMP)" --format=custom "--dbname=postgres://wiki@127.0.0.1:$first_port/kept" >"$work/kept.dump" \
  && "$(variable first WIKI_TEST_PG_RESTORE)" --list <"$work/kept.dump" | grep -q 'TABLE DATA public t'; then
  pass 'pg_dump takes the host'"'"'s URL as --dbname, and pg_restore reads its dump'
else
  fail 'pg_dump and pg_restore through the host'"'"'s URL'
fi

# The second start, while a query runs: the same container, the same port,
# the database made in between, and the query finishes.
query first 'SELECT pg_sleep(4)' >"$work/sleep.out" 2>&1 &
sleeping=$!
sleep 1
if ci_postgres start first && [ "$(id_of first)" = "$first_id" ] && [ "$(port_of first)" = "$first_port" ] \
  && [ "$(query first "SELECT count(*) FROM pg_database WHERE datname = 'kept'")" = 1 ] && wait "$sleeping"; then
  pass 'start on a container that runs and answers leaves it, its port and a query in flight alone'
else
  fail 'the second start'
  cat "$work/first.out" "$work/first.err" "$work/sleep.out" >&2
fi

# env: the same variables, and nothing started for a name that does not run.
cp "$work/first.out" "$work/first.started"
if ci_postgres env first && cmp -s "$work/first.out" "$work/first.started"; then
  pass 'env prints the variables of the running container'
else
  fail 'env on a running container'
fi
if ci_postgres env absent; then
  fail 'env on a container that does not run succeeded'
elif [ -n "$(id_of absent)" ]; then
  fail 'env made a container'
else
  pass 'env on a container that does not run fails, and starts nothing'
fi

# A second container beside the first, with the ports after the first's
# held by another process where they were free: rootless Docker chooses the
# next port of its range, and the script asks it again when one is held.
node -e '
  const net = require("node:net");
  for (const port of process.argv.slice(1).map(Number)) net.createServer().listen(port, "127.0.0.1").on("error", () => {});
' $((first_port + 1)) $((first_port + 2)) $((first_port + 3)) &
holder=$!
sleep 1
if ci_postgres start second && second_port=$(port_of second) && [ -n "$second_port" ] \
  && [ "$second_port" != "$first_port" ] && { [ "$second_port" -lt $((first_port + 1)) ] || [ "$second_port" -gt $((first_port + 3)) ]; } \
  && [ "$(query second 'SELECT 1')" = 1 ] && [ "$(query first 'SELECT 1')" = 1 ]; then
  pass "a second container starts beside the first while ports after the first's are held (it took $second_port)"
else
  fail 'a second container beside the first, with ports held'
  cat "$work/second.out" "$work/second.err" >&2
fi
kill "$holder" 2>/dev/null || true
holder=''

# A stopped container is made again; restart always makes a new one.
docker stop "$prefix-second" >/dev/null
stopped_id=$(id_of second)
if ci_postgres start second && [ "$(id_of second)" != "$stopped_id" ] && [ "$(query second 'SELECT 1')" = 1 ]; then
  pass 'start makes a stopped container again'
else
  fail 'start on a stopped container'
  cat "$work/second.out" "$work/second.err" >&2
fi
before=$(id_of second)
if ci_postgres restart second && [ "$(id_of second)" != "$before" ] && [ "$(query second 'SELECT 1')" = 1 ]; then
  pass 'restart makes a new container'
else
  fail 'restart'
  cat "$work/second.out" "$work/second.err" >&2
fi

# Two starts at once, of a name that does not run: one container, which
# both print.
WIKI_CI_POSTGRES_NAME=$prefix-twin sh "$script" start "$work/bin-twin-a" >"$work/twin-a.out" 2>"$work/twin-a.err" &
twin_a=$!
WIKI_CI_POSTGRES_NAME=$prefix-twin sh "$script" start "$work/bin-twin-b" >"$work/twin-b.out" 2>"$work/twin-b.err" &
twin_b=$!
if wait "$twin_a" && wait "$twin_b" && [ -n "$(port_of twin-a)" ] && [ "$(port_of twin-a)" = "$(port_of twin-b)" ] \
  && [ "$(query twin-a 'SELECT 1')" = 1 ]; then
  pass 'two starts at once make one container, and both print it'
else
  fail 'two starts at once'
  cat "$work/twin-a.out" "$work/twin-a.err" "$work/twin-b.out" "$work/twin-b.err" >&2
fi

# A container as the script's earlier version made it: PostgreSQL on 55432
# inside (here published on a host port Docker chooses).
docker run --detach --name "$prefix-legacy" --env POSTGRES_USER=wiki --env POSTGRES_HOST_AUTH_METHOD=trust \
  --publish 127.0.0.1::55432 postgres:17 -c port=55432 >/dev/null
legacy_id=$(id_of legacy)
if ci_postgres start legacy && [ "$(id_of legacy)" = "$legacy_id" ] && [ "$(query legacy 'SHOW port')" = 55432 ] \
  && "$(variable legacy WIKI_TEST_PG_DUMP)" --schema-only "--dbname=$(variable legacy WIKI_TEST_DATABASE_URL)" >/dev/null; then
  pass 'a container of the earlier version, with another port inside, is kept and reached'
else
  fail 'a container of the earlier version'
  cat "$work/legacy.out" "$work/legacy.err" >&2
fi

# stop removes it.
if ci_postgres stop first && [ -z "$(id_of first)" ]; then
  pass 'stop removes the container'
else
  fail 'stop'
fi

[ "$failures" -eq 0 ] || exit 1
