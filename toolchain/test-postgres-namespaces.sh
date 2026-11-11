#!/bin/sh
# Runs of the server's PostgreSQL tests that share one server, as the
# sessions on one machine share toolchain/ci-postgres.sh's container: two
# runs at once both pass, and leave none of their databases behind; a run
# killed part-way leaves its databases, and the next run passes all the
# same; and a run drops a dead run's databases once they are six hours old,
# and leaves younger ones, which may be a live run's (Test.Database's
# namespaceFor and sweepOnce).
#
#   sh toolchain/test-postgres-namespaces.sh SERVER_TEST
#
# SERVER_TEST is the built wiki-server-test. It reads the variables
# toolchain/ci-postgres.sh prints (WIKI_TEST_DATABASE_URL, WIKI_TEST_PSQL,
# WIKI_TEST_PG_DUMP, WIKI_TEST_PG_RESTORE), and runs two small groups of the
# PostgreSQL tests, the backups' and the schema's versions', which make
# databases both from the run's template and from nothing. About a minute.
# The names' length (PostgreSQL's 63 bytes) and shape are the unit tests'
# (Test.Database.namesUnitSpec). Run it on a server no other run uses, as
# CI's container for one job: it counts the databases that appear while it
# runs, and drops them all at the end.
set -eu
server_test=${1:?usage: sh toolchain/test-postgres-namespaces.sh SERVER_TEST}
: "${WIKI_TEST_DATABASE_URL:?run toolchain/ci-postgres.sh start first}"
: "${WIKI_TEST_PSQL:?run toolchain/ci-postgres.sh start first}"
cd "$(dirname "$0")/../wiki-server"

work=$(mktemp -d)
killed=''
cleanup() {
  [ -z "$killed" ] || kill -9 "-$killed" 2>/dev/null || true
  for db in $(listing | grep -vxF -f "$work/before" || true); do
    sql "DROP DATABASE IF EXISTS $db WITH (FORCE)" >/dev/null 2>&1 || true
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
sql() { "$WIKI_TEST_PSQL" "$WIKI_TEST_DATABASE_URL" -tA -c "$1"; }
# The databases in the tests' namespace (and of the shape before it).
listing() { sql "SELECT datname FROM pg_database WHERE datname LIKE 'wiki\_test\_%' ORDER BY 1"; }
# One run of the two groups, its output in $work/<name>.log. It is started
# in the background as `run NAME &`: the exec makes the background job the
# test program itself, not a subshell that waits for it, so that $! is the
# program's pid; and setsid puts the program in a process group of its own,
# whose id is that pid, so that `kill -9 -$!` reaches the program and every
# process it started (the pg_dump and psql it runs, through docker exec).
# A background job of a non-interactive shell leads no process group, so
# setsid makes the new session in place, without a fork.
run() {
  WIKI_TEST_GROUP=postgres exec setsid "$server_test" --match "/on PostgreSQL/backup/" --match "/on PostgreSQL/the schema's versions/" >"$work/$1.log" 2>&1
}
# Whether any process of the process group is left.
# (dash's kill takes no "--": a process group is "-PGID" right after the
# signal.)
group_alive() { kill -0 "-$1" 2>/dev/null; }
# The sessions PostgreSQL has on the databases listed in the file.
sessions_on() {
  names=$(sed "s/.*/'&'/" "$1" | paste -sd, -)
  sql "SELECT count(*) FROM pg_stat_activity WHERE datname IN ($names)"
}

listing >"$work/before"
now=$(date +%s)
stale=wiki_test_$((now - 7 * 3600))_stale001_1
young=wiki_test_$((now - 3600))_young001_1
sql "CREATE DATABASE $stale" >/dev/null
sql "CREATE DATABASE $young" >/dev/null

# Two runs at once.
run a &
a=$!
run b &
b=$!
a_passed='' b_passed=''
if wait "$a"; then a_passed=1; fi
if wait "$b"; then b_passed=1; fi
if [ -n "$a_passed" ] && [ -n "$b_passed" ]; then
  pass 'two runs at once on one server both pass'
else
  fail 'two runs at once'
  tail -n 30 "$work/a.log" "$work/b.log" >&2
fi
listing | grep -vxF -f "$work/before" >"$work/after" || true
if [ "$(cat "$work/after")" = "$young" ]; then
  pass 'they leave none of their databases, drop a dead run'"'"'s seven hours old, and leave one an hour old'
else
  fail 'what the runs left'
  printf 'expected only %s, found:\n' "$young" >&2
  cat "$work/after" >&2
fi

# A run killed part-way, then another.
cp "$work/before" "$work/known"
printf '%s\n' "$young" >>"$work/known"
run killed &
killed=$!
tries=0
until listing | grep -vxF -f "$work/known" | grep -q .; do
  tries=$((tries + 1))
  if [ "$tries" -gt 600 ]; then break; fi
  sleep 0.1
done
kill -9 "-$killed"
wait "$killed" 2>/dev/null || true
# Dead: no process of the run is left, and, once the commands it ran in the
# container (which docker exec does not stop with its client) have ended,
# PostgreSQL has no session on its databases.
dead=''
if ! kill -0 "$killed" 2>/dev/null && ! group_alive "$killed"; then
  listing | grep -vxF -f "$work/known" >"$work/left" || true
  tries=0
  while [ -s "$work/left" ] && [ "$(sessions_on "$work/left")" != 0 ] && [ "$tries" -lt 300 ]; do
    tries=$((tries + 1))
    sleep 0.1
  done
  [ ! -s "$work/left" ] || [ "$(sessions_on "$work/left")" != 0 ] || dead=1
fi
killed_pid=$killed
killed=''
if [ -z "$dead" ]; then
  fail "the killed run is not dead (pid $killed_pid, or a session on its databases)"
elif [ -s "$work/left" ] && (run next) && [ -z "$(listing | grep -vxF -f "$work/known" | grep -vxF -f "$work/left")" ]; then
  pass "a run killed part-way, its processes gone and its databases unused, leaves $(wc -l <"$work/left") databases, and the next run passes all the same and leaves none of its own"
else
  fail 'a run after a killed one'
  cat "$work/left" >&2
  tail -n 30 "$work/next.log" >&2
fi

[ "$failures" -eq 0 ] || exit 1
