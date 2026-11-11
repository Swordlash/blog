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
# yet, and makes a new one only when there is none, or the one there does
# not run or does not answer. `restart` always makes a new one. Both wait
# until PostgreSQL answers. `start`, `restart` and `stop` of one name take a
# lock (flock on $XDG_RUNTIME_DIR/ci-postgres.<name>.lock, else in /tmp), so
# that two of them never act on the same container at once; `env` only
# reads, and takes none.
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
# (toolchain/smoke-test.sh). Since `start` keeps a container that runs,
# several runs may use it at once and one after another: each names its
# databases in a namespace of its own (wiki_test_<time>_<random>_), and the
# server's tests drop a dead run's once they are six hours old. `restart`
# gives an empty server. pg_dump, pg_restore and psql are scripts written
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

# Run a new container of that name, on a host port Docker chooses. Rootless
# Docker chooses the next port of its range without checking that the host
# has it free, and fails to start the container when another process holds
# it ("address already in use"): the container made is then removed, by its
# id, and Docker asked again, which gives the port after it; ten times at
# most. The caller holds the lock ('lock'), so no other `start` makes a
# container of the name meanwhile. One made by something that does not take
# the lock (an older copy of this script, a person) makes the run fail with
# the name taken, and that container is used once it runs.
create() {
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
      tries=0
      until published; do
        tries=$((tries + 1))
        [ "$tries" -le 30 ] || break
        sleep 1
      done
      break
    fi
    attempt=$((attempt + 1))
    # Rootless Docker says "address already in use"; Docker as root has
    # said "failed to bind host port" and "port is already allocated".
    if grep -q 'address already in use\|failed to bind host port\|port is already allocated' "$scratch/error" && [ "$attempt" -lt 10 ]; then
      [ ! -s "$scratch/id" ] || docker rm -f "$(cat "$scratch/id")" >/dev/null 2>&1 || true
      continue
    fi
    cat "$scratch/error" >&2
    [ ! -s "$scratch/id" ] || docker rm -f "$(cat "$scratch/id")" >/dev/null 2>&1 || true
    rm -rf "$scratch"
    exit 1
  done
  rm -rf "$scratch"
  if ! published || ! answers_soon; then
    docker logs "$name" >&2 || true
    printf 'ci-postgres: PostgreSQL in %s did not answer in a minute\n' "$name" >&2
    exit 1
  fi
}

# Take the lock of the container's name, held until the script exits:
# `start`, `restart` and `stop` of one name run one at a time, so that what
# one of them sees of the container stays true until it is done. The lock
# is flock(1) on a file in $XDG_RUNTIME_DIR (the account's runtime
# directory, which rootless Docker uses too, the same in every session of
# the account), else in /tmp. The kernel releases it when the process ends,
# however it ends, so a killed `start` leaves nothing that blocks the next
# one. Without flock the script runs unlocked, and says so.
lock() {
  lock_file=${XDG_RUNTIME_DIR:-/tmp}/ci-postgres.$name.lock
  if ! command -v flock >/dev/null 2>&1; then
    printf 'ci-postgres: no flock here; %s runs without the lock that keeps two starts of %s apart\n' "$1" "$name" >&2
    return 0
  fi
  exec 9>>"$lock_file"
  if ! flock --wait 600 9; then
    printf 'ci-postgres: %s was held for ten minutes; giving up\n' "$lock_file" >&2
    exit 1
  fi
}

# For the script's tests only: with WIKI_CI_POSTGRES_TEST_PAUSE set to a
# file's path, wait under the lock, after looking at the container, until
# that file is removed. The wait is announced by a file of the same path
# with ".paused" after it.
pause_for_test() {
  [ -n "${WIKI_CI_POSTGRES_TEST_PAUSE:-}" ] || return 0
  : >"$WIKI_CI_POSTGRES_TEST_PAUSE.paused"
  while [ -e "$WIKI_CI_POSTGRES_TEST_PAUSE" ]; do
    sleep 0.1 9>&-
  done
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
    lock start
    status=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || true)
    pause_for_test
    # None: make one. One that runs is kept if it answers within a minute
    # (it may have just been made); one that does not answer, or does not
    # run, is made again.
    if [ -z "$status" ]; then
      create
    elif [ "$status" != running ] || ! published || ! answers_soon; then
      docker rm -f "$name" >/dev/null 2>&1 || true
      create
    fi
    print_variables "${2:-$(mktemp -d)}"
    ;;
  env)
    # env only reads, so it takes no lock: a container another start is
    # making, which does not answer yet, is reported as not answering.
    docker_answers
    if ! published || ! answers; then
      printf 'ci-postgres: %s does not run or does not answer; start it with: sh toolchain/ci-postgres.sh start\n' "$name" >&2
      exit 1
    fi
    print_variables "${2:-$(mktemp -d)}"
    ;;
  restart)
    docker_answers
    lock restart
    pause_for_test
    docker rm -f "$name" >/dev/null 2>&1 || true
    create
    print_variables "${2:-$(mktemp -d)}"
    ;;
  stop)
    lock stop
    pause_for_test
    docker rm -f "$name" >/dev/null 2>&1 || true
    ;;
  *)
    usage
    ;;
esac
