#!/bin/sh
# PostgreSQL for CI's tests of the wiki's server, in a container: postgres:17,
# the major version docker-compose.yml deploys.
#
#   sh toolchain/ci-postgres.sh start   # start it, and print the variables to export
#   sh toolchain/ci-postgres.sh stop    # remove it
#
# `start` runs the container wiki-ci-postgres, which trusts every connection
# (it listens on 127.0.0.1 only, and lives for one job), on port 55432 both
# inside the container and on the host, so that the same URL works from
# either. It waits until the server answers, writes pg_dump and pg_restore
# that run the container's own (a pg_dump older than the server refuses it,
# and the runner's may be older), and psql, into the directory given as the
# second argument (default: a temporary one), and prints, one per line,
#
#   WIKI_TEST_DATABASE_URL=postgres://wiki@127.0.0.1:55432/postgres
#   WIKI_TEST_PG_DUMP=<dir>/pg_dump
#   WIKI_TEST_PG_RESTORE=<dir>/pg_restore
#   WIKI_TEST_PSQL=<dir>/psql
#
# for $GITHUB_ENV: the server's test suite then runs its PostgreSQL half on
# it (wiki-server/test/Test/Database.hs), and the smoke test its server
# (toolchain/smoke-test.sh). Without Docker it says so and
# fails, and the caller decides what that means.
set -eu

name=wiki-ci-postgres
port=55432

case ${1:-} in
  start)
    bin=${2:-$(mktemp -d)}
    if ! docker info >/dev/null 2>&1; then
      printf 'ci-postgres: Docker does not answer here\n' >&2
      exit 1
    fi
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run --detach --name "$name" \
      --env POSTGRES_USER=wiki --env POSTGRES_HOST_AUTH_METHOD=trust \
      --publish "127.0.0.1:$port:$port" \
      postgres:17 -c "port=$port" -c fsync=off -c synchronous_commit=off >/dev/null
    tries=0
    until docker exec "$name" pg_isready --host=127.0.0.1 --port="$port" --username=wiki >/dev/null 2>&1; do
      tries=$((tries + 1))
      if [ "$tries" -gt 60 ]; then
        docker logs "$name" >&2 || true
        printf 'ci-postgres: PostgreSQL did not answer in a minute\n' >&2
        exit 1
      fi
      sleep 1
    done
    mkdir -p "$bin"
    for program in pg_dump pg_restore psql; do
      printf '#!/bin/sh\n# %s of the container %s, written by toolchain/ci-postgres.sh.\nexec docker exec --interactive %s %s "$@"\n' \
        "$program" "$name" "$name" "$program" >"$bin/$program"
      chmod +x "$bin/$program"
    done
    printf 'WIKI_TEST_DATABASE_URL=postgres://wiki@127.0.0.1:%s/postgres\n' "$port"
    printf 'WIKI_TEST_PG_DUMP=%s/pg_dump\n' "$bin"
    printf 'WIKI_TEST_PG_RESTORE=%s/pg_restore\n' "$bin"
    printf 'WIKI_TEST_PSQL=%s/psql\n' "$bin"
    ;;
  stop)
    docker rm -f "$name" >/dev/null 2>&1 || true
    ;;
  *)
    printf 'usage: sh toolchain/ci-postgres.sh start [DIR] | stop\n' >&2
    exit 2
    ;;
esac
