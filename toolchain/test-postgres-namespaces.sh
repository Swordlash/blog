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
  [ -z "$killed" ] || kill -9 "$killed" 2>/dev/null || true
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
# One run of the two groups, its output in $work/<name>.log.
run() {
  WIKI_TEST_GROUP=postgres "$server_test" --match "/on PostgreSQL/backup/" --match "/on PostgreSQL/the schema's versions/" >"$work/$1.log" 2>&1
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
kill -9 "$killed" 2>/dev/null || true
wait "$killed" 2>/dev/null || true
killed=''
listing | grep -vxF -f "$work/known" >"$work/left" || true
if [ -s "$work/left" ] && run next; then
  pass "a run killed part-way leaves $(wc -l <"$work/left") databases, and the next run passes all the same"
else
  fail 'a run after a killed one'
  cat "$work/left" >&2
  tail -n 30 "$work/next.log" >&2
fi

[ "$failures" -eq 0 ] || exit 1
