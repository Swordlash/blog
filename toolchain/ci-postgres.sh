#!/bin/sh
# PostgreSQL for the tests of the wiki's server, in a container: postgres:17,
# the major version docker-compose.yml deploys. CI starts it for one job; on a
# machine shared by several sessions, one container serves them all.
#
#   sh toolchain/ci-postgres.sh start [DIR]    # start it unless it runs, and print the variables to export
#   sh toolchain/ci-postgres.sh env [DIR]      # print the variables of the running container, start nothing
#   sh toolchain/ci-postgres.sh restart [DIR]  # remove it, start a new one, and print the variables
#   sh toolchain/ci-postgres.sh stop           # remove it
#
# The container is named wiki-ci-postgres, or $WIKI_CI_POSTGRES_NAME: two
# checkouts that set different names run side by side. It trusts every
# connection (it is published on 127.0.0.1 only). Docker chooses the host's
# port (`--publish 127.0.0.1::5432`), and the script reads it back with
# `docker port`: no port is picked by number. Rootless Docker does not check
# that the port it chooses is free on the host; when another process holds
# it, the script asks Docker again, and Docker chooses the next one.
#
# `start` leaves a container that runs and answers as it is: other test runs
# may be using it. It waits a minute for one that runs but does not answer
# yet (another `start` may have just made it), and makes a new one only when
# none runs or the one that runs does not answer. `restart` always makes a
# new one. Both wait until PostgreSQL answers.
#
# The variables are printed one per line, for $GITHUB_ENV:
#
#   WIKI_TEST_DATABASE_URL=postgres://wiki@127.0.0.1:<port>/postgres
#   WIKI_TEST_PG_DUMP=<dir>/pg_dump
#   WIKI_TEST_PG_RESTORE=<dir>/pg_restore
#   WIKI_TEST_PSQL=<dir>/psql
#
# The server's test suite then runs its PostgreSQL half on it
# (wiki-server/test/Test/Database.hs), and the smoke test its server
# (toolchain/smoke-test.sh). pg_dump, pg_restore and psql are scripts written
# into DIR (default: a temporary directory) that run the container's own
# programs with `docker exec`: a pg_dump older than the server refuses it,
# and the runner's may be older. Inside the container PostgreSQL listens on
# another port than the host's, so these scripts rewrite the host's address
# (127.0.0.1:<port>) in their arguments to the container's. A container made
# by an earlier version of this script, with the same port inside and out,
# is read the same way: the script reads both ports from Docker.
#
# Without Docker the script says so and fails, and the caller decides what
# that means.
set -eu

name=${WIKI_CI_POSTGRES_NAME:-wiki-ci-postgres}

usage() {
  printf 'usage: sh toolchain/ci-postgres.sh start [DIR] | env [DIR] | restart [DIR] | stop\n' >&2
  exit 2
}

docker_answers() {
  if ! docker info >/dev/null 2>&1; then
    printf 'ci-postgres: Docker does not answer here\n' >&2
    exit 1
  fi
}

# Set inside and outside to the container's published TCP port: the port
# PostgreSQL listens on in the container, and the host's port Docker
# forwards to it. Fails when the container does not run or publishes no
# port on 127.0.0.1.
published() {
  [ "$(docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null)" = true ] || return 1
  # One line per published port: "5432/tcp -> 127.0.0.1:49153".
  mapping=$(docker port "$name" 2>/dev/null | sed -n 's|^\([0-9]*\)/tcp -> 127\.0\.0\.1:\([0-9]*\)$|\1 \2|p' | head -n 1)
  [ -n "$mapping" ] || return 1
  inside=${mapping% *}
  outside=${mapping#* }
}

# Whether PostgreSQL in the container answers on its port.
answers() {
  docker exec "$name" pg_isready --host=127.0.0.1 --port="$inside" --username=wiki >/dev/null 2>&1
}

# Wait for the container to answer, a minute at most.
answers_soon() {
  tries=0
  until answers; do
    tries=$((tries + 1))
    [ "$tries" -le 60 ] || return 1
    sleep 1
  done
}

# Remove the container given (an id, or the name; none when empty), and
# run a new one, on a host port Docker chooses. `start` gives the id of the
# container it found unusable, not the name: a container another `start`
# has made since is then not removed. Rootless Docker chooses the next port
# of its range without checking that the host has it free, and fails to
# start the container when another process holds it ("address already in
# use"): the container made is then removed, by its id, and Docker asked
# again, which gives the port after it; ten times at most. When the run
# fails because another `start` has just made a container of the same name,
# that container is used.
create() {
  [ -z "$1" ] || docker rm -f "$1" >/dev/null 2>&1 || true
  scratch=$(mktemp -d)
  attempt=0
  while :; do
    rm -f "$scratch/id"
    if docker run --detach --name "$name" --cidfile "$scratch/id" \
      --env POSTGRES_USER=wiki --env POSTGRES_HOST_AUTH_METHOD=trust \
      --publish 127.0.0.1::5432 \
      postgres:17 -c fsync=off -c synchronous_commit=off >/dev/null 2>"$scratch/error"; then
      break
    fi
    if grep -q 'is already in use by container' "$scratch/error"; then
      break
    fi
    attempt=$((attempt + 1))
    if grep -q 'address already in use' "$scratch/error" && [ "$attempt" -lt 10 ]; then
      [ ! -s "$scratch/id" ] || docker rm -f "$(cat "$scratch/id")" >/dev/null 2>&1 || true
      continue
    fi
    cat "$scratch/error" >&2
    [ ! -s "$scratch/id" ] || docker rm -f "$(cat "$scratch/id")" >/dev/null 2>&1 || true
    rm -rf "$scratch"
    exit 1
  done
  rm -rf "$scratch"
  # Another start's container may not run yet: wait for it to run as well.
  tries=0
  until published; do
    tries=$((tries + 1))
    [ "$tries" -le 30 ] || break
    sleep 1
  done
  if ! published || ! answers_soon; then
    docker logs "$name" >&2 || true
    printf 'ci-postgres: PostgreSQL in %s did not answer in a minute\n' "$name" >&2
    exit 1
  fi
}

# Write pg_dump, pg_restore and psql into the directory, and print the
# variables.
print_variables() {
  bin=$1
  mkdir -p "$bin"
  for program in pg_dump pg_restore psql; do
    cat >"$bin/$program" <<EOF
#!/bin/sh
# $program of the container $name, written by toolchain/ci-postgres.sh. The
# container's PostgreSQL listens on port $inside; the host reaches it on port
# $outside. An argument naming the host's address is rewritten to the
# container's, since the program runs in the container.
for argument do
  shift
  case \$argument in
    *127.0.0.1:$outside/*) argument=\$(printf '%s\n' "\$argument" | sed 's|127\.0\.0\.1:$outside/|127.0.0.1:$inside/|g') ;;
  esac
  set -- "\$@" "\$argument"
done
exec docker exec --interactive $name $program "\$@"
EOF
    chmod +x "$bin/$program"
  done
  printf 'WIKI_TEST_DATABASE_URL=postgres://wiki@127.0.0.1:%s/postgres\n' "$outside"
  printf 'WIKI_TEST_PG_DUMP=%s/pg_dump\n' "$bin"
  printf 'WIKI_TEST_PG_RESTORE=%s/pg_restore\n' "$bin"
  printf 'WIKI_TEST_PSQL=%s/psql\n' "$bin"
}

case ${1:-} in
  start)
    docker_answers
    seen=$(docker inspect --format '{{.Id}}' "$name" 2>/dev/null || true)
    if ! published || ! answers_soon; then
      create "$seen"
    fi
    print_variables "${2:-$(mktemp -d)}"
    ;;
  env)
    docker_answers
    if ! published || ! answers; then
      printf 'ci-postgres: %s does not run or does not answer; start it with: sh toolchain/ci-postgres.sh start\n' "$name" >&2
      exit 1
    fi
    print_variables "${2:-$(mktemp -d)}"
    ;;
  restart)
    docker_answers
    create "$name"
    print_variables "${2:-$(mktemp -d)}"
    ;;
  stop)
    docker rm -f "$name" >/dev/null 2>&1 || true
    ;;
  *)
    usage
    ;;
esac
