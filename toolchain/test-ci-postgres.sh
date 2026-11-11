#!/bin/sh
# Tests of toolchain/ci-postgres.sh, against real containers of names of the
# test's own: `start` twice in a row gives the same container and port, and
# leaves a query in flight alone; `env` prints the variables of a running
# container and starts nothing; the pg_dump and psql it writes reach the
# container's PostgreSQL through the host's address; a host port another
# process holds does not stop a second container from starting beside the
# first; a stopped container is made again, as `restart` always does; a
# container made by the script's earlier version, with PostgreSQL on another
# port inside, is read as it is; and the lock that keeps `start`, `restart`
# and `stop` of one name apart: eight starts at once make one container,
# which each prints; a start that has looked and found none holds back a
# second until it has made the container; a start during a restart and a
# stop during a start wait for it; and a killed start leaves no lock behind.
# The script's WIKI_CI_POSTGRES_TEST_PAUSE holds one of them, under the
# lock, after it has looked, so that the order of each case is fixed.
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
  for suffix in first second legacy absent many held killed; do
    docker rm -f "$prefix-$suffix" >/dev/null 2>&1 || true
    rm -f "${XDG_RUNTIME_DIR:-/tmp}/ci-postgres.$prefix-$suffix.lock"
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
# Wait for a file to exist, thirty seconds at most.
wait_for() {
  tries=0
  until [ -e "$1" ]; do
    tries=$((tries + 1))
    [ "$tries" -le 300 ] || return 1
    sleep 0.1
  done
}
# Run the script for the suffix, held after it has looked until the file
# $work/pause is removed, in the background; its output goes to
# $work/<out>.out. The background job is the one simple command, so the
# shell starts the script in it directly and $! is the script's own pid
# (dash and bash alike), the process that holds the lock; held and behind
# are called, not put in the background themselves.
held() {
  rm -f "$work/pause.paused"
  : >"$work/pause"
  WIKI_CI_POSTGRES_TEST_PAUSE=$work/pause WIKI_CI_POSTGRES_NAME=$prefix-$2 sh "$script" "$1" "$work/bin-$3" >"$work/$3.out" 2>"$work/$3.err" &
}
# Run the script for the suffix in the background, unheld; its output goes
# to $work/<out>.out.
behind() {
  WIKI_CI_POSTGRES_NAME=$prefix-$2 sh "$script" "$1" "$work/bin-$3" >"$work/$3.out" 2>"$work/$3.err" &
}
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

# Eight starts at once, of a name that does not run, in two rounds: each
# round makes one container, which every start prints.
for round in 1 2; do
  docker rm -f "$prefix-many" >/dev/null 2>&1 || true
  pids=''
  for i in 1 2 3 4 5 6 7 8; do
    behind start many "many-$i"
    pids="$pids $!"
  done
  all=1
  for pid in $pids; do
    wait "$pid" || all=''
  done
  ports=$(for i in 1 2 3 4 5 6 7 8; do port_of "many-$i"; done | sort -u)
  if [ -n "$all" ] && [ -n "$ports" ] && [ "$(printf '%s\n' "$ports" | wc -l)" -eq 1 ] \
    && [ "$(docker ps --all --quiet --filter "name=^/$prefix-many\$" | wc -l)" -eq 1 ] && [ "$(query many-1 'SELECT 1')" = 1 ]; then
    pass "eight starts at once make one container, and each prints its port (round $round)"
  else
    fail "eight starts at once (round $round)"
    for i in 1 2 3 4 5 6 7 8; do cat "$work/many-$i.out" "$work/many-$i.err" >&2; done
  fi
done

# The interleaving the lock is for: a start looks and finds nothing; a
# second start then waits, and makes nothing, until the first has made the
# container; both print it.
held start held held-a
first_start=$!
wait_for "$work/pause.paused"
behind start held held-b
second_start=$!
sleep 2
if kill -0 "$second_start" 2>/dev/null && [ -z "$(id_of held)" ]; then
  waited=1
else
  waited=''
fi
rm -f "$work/pause"
if [ -n "$waited" ] && wait "$first_start" && wait "$second_start" && [ -n "$(port_of held-a)" ] \
  && [ "$(port_of held-a)" = "$(port_of held-b)" ] && [ "$(query held-b 'SELECT 1')" = 1 ]; then
  pass 'a start that found no container holds back a second start until it has made one, which both print'
else
  fail 'a second start while the first makes the container'
  cat "$work/held-a.err" "$work/held-b.err" >&2
fi

# A start during a restart waits for it, and prints the new container.
before=$(id_of held)
held restart held restarted
restarting=$!
wait_for "$work/pause.paused"
behind start held during-restart
starting=$!
sleep 1
if kill -0 "$starting" 2>/dev/null; then waited=1; else waited=''; fi
rm -f "$work/pause"
if [ -n "$waited" ] && wait "$restarting" && wait "$starting" && [ "$(id_of held)" != "$before" ] \
  && [ -n "$(port_of restarted)" ] && [ "$(port_of restarted)" = "$(port_of during-restart)" ] && [ "$(query during-restart 'SELECT 1')" = 1 ]; then
  pass 'a start during a restart waits for it, and prints the new container'
else
  fail 'a start during a restart'
  cat "$work/restarted.err" "$work/during-restart.err" >&2
fi

# A stop during a start waits for the start to finish, then removes the
# container.
held start held started
starting=$!
wait_for "$work/pause.paused"
behind stop held stopping
stopping=$!
sleep 1
if kill -0 "$stopping" 2>/dev/null && [ -n "$(id_of held)" ]; then waited=1; else waited=''; fi
rm -f "$work/pause"
if [ -n "$waited" ] && wait "$starting" && wait "$stopping" && [ -n "$(port_of started)" ] && [ -z "$(id_of held)" ]; then
  pass 'a stop during a start waits for the start, then removes the container'
else
  fail 'a stop during a start'
  cat "$work/started.err" "$work/stopping.err" >&2
fi

# A start killed while it holds the lock leaves nothing that blocks the
# next: the kernel releases the lock with the process.
# The process killed is the one that holds the lock: the lock is taken
# while it waits, free at once when it is gone.
lock_file=${XDG_RUNTIME_DIR:-/tmp}/ci-postgres.$prefix-killed.lock
held start killed killed
killed=$!
wait_for "$work/pause.paused"
if flock --nonblock "$lock_file" true; then taken_before=''; else taken_before=1; fi
kill -9 "$killed"
wait "$killed" 2>/dev/null || true
if [ -n "$taken_before" ] && ! kill -0 "$killed" 2>/dev/null && flock --nonblock "$lock_file" true; then
  pass 'the start killed is the process that held the lock: it is gone, and the lock free at once'
else
  fail 'the killed start: not the lock'"'"'s holder, or the lock still taken'
fi
if timeout 120 env WIKI_CI_POSTGRES_NAME="$prefix-killed" sh "$script" start "$work/bin-after-kill" >"$work/after-kill.out" 2>"$work/after-kill.err" \
  && [ "$(query after-kill 'SELECT 1')" = 1 ]; then
  pass 'a start killed while it holds the lock does not block the next one'
else
  fail 'a start after a killed start'
  cat "$work/after-kill.err" >&2
fi
rm -f "$work/pause"

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
