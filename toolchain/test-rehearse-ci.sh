#!/bin/sh
# Regression tests of toolchain/rehearse-ci.sh's ports, against a fake OLD
# wiki-server and a fake NEW one: the script chooses no port, but starts the
# old server on port 0 for both listeners and reads the admin listener's
# address from the server's log; two runs side by side do not collide; a
# port another process holds is never the one used; the move to PostgreSQL
# (--move) starts the old server the same way; and a server that fails, or
# never logs its address, fails the script.
#
#   sh toolchain/test-rehearse-ci.sh
#
# The fake OLD listens where it is told, as wiki-server does: port 0 is a
# port the system gives. It logs each listener's address in wiki-server's
# words and answers the few requests the script makes on the admin one. The
# fake NEW records its arguments and succeeds. Nothing but loopback is used.
set -eu
cd "$(dirname "$0")/.."
script=$(pwd)/toolchain/rehearse-ci.sh

work=$(mktemp -d)
holder=''
trap '[ -z "$holder" ] || kill "$holder" 2>/dev/null || true; rm -rf "$work"' EXIT
failures=0

pass() { printf 'ok: %s\n' "$1"; }
fail() {
  printf 'FAILED: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# The fake OLD. Each start's --listen and --admin-listen are recorded in
# $FAKE_DIR/asked, and the ports it took in $FAKE_DIR/took.
# $FAKE_BROKEN makes it fail at once; $FAKE_SILENT makes it serve without
# logging its addresses.
cat >"$work/old" <<'EOF'
#!/bin/sh
set -eu
listen='' admin=''
while [ "$#" -gt 0 ]; do
  case $1 in
    --listen) listen=$2; shift ;;
    --admin-listen) admin=$2; shift ;;
  esac
  shift
done
printf '%s %s\n' "$listen" "$admin" >>"$FAKE_DIR/asked"
echo $$ >"$FAKE_DIR/pid"
if [ -n "${FAKE_BROKEN:-}" ]; then
  echo 'wiki-server: the database cannot be opened' >&2
  exit 1
fi
exec node -e '
  const http = require("http");
  const fs = require("fs");
  const [listen, admin, took, silent] = process.argv.slice(1);
  const at = (address) => ({ host: address.slice(0, address.lastIndexOf(":")), port: Number(address.slice(address.lastIndexOf(":") + 1)) });
  const serve = (address, name, mount) =>
    new Promise((ready) => {
      const server = http.createServer((req, res) => {
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify({ id: "made", homePage: "home" }));
      });
      server.listen(at(address).port, at(address).host, () => {
        const port = server.address().port;
        if (!silent) console.log(`level=info event=listening listener=${name} address=http://127.0.0.1:${port}${mount} principal=x`);
        ready(port);
      });
    });
  Promise.all([serve(listen, "public", "/"), serve(admin, "admin", "/admin/")]).then((ports) => fs.appendFileSync(took, ports.join(" ") + "\n"));
' "$listen" "$admin" "$FAKE_DIR/took" "${FAKE_SILENT:-}"
EOF
cat >"$work/new" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$FAKE_DIR/new.args"
EOF
chmod +x "$work/old" "$work/new"

# Run the script with these fakes, the settings given and the script's
# option in $mode, with records in the directory given.
mode=''
run() {
  dir=$1
  shift
  mkdir -p "$dir"
  rm -f "$dir/asked" "$dir/took" "$dir/new.args" "$dir/pid"
  # shellcheck disable=SC2086 # $mode is one word or none.
  env FAKE_DIR="$dir" "$@" sh "$script" "$work/old" "$work/new" $mode >"$dir/out" 2>&1
}
# The same, started in the background as `run_behind DIR ... &`: the exec
# makes the background job the script itself, not a subshell that waits for
# it, so that $! is the script's pid, and a signal sent to $! reaches it.
run_behind() {
  dir=$1
  shift
  mkdir -p "$dir"
  rm -f "$dir/asked" "$dir/took" "$dir/new.args" "$dir/pid"
  # shellcheck disable=SC2086 # $mode is one word or none.
  exec env FAKE_DIR="$dir" "$@" sh "$script" "$work/old" "$work/new" $mode >"$dir/out" 2>&1
}
asked_zero() { [ "$(cat "$1/asked")" = '127.0.0.1:0 127.0.0.1:0' ]; }

if run "$work/one" && [ -f "$work/one/new.args" ] && asked_zero "$work/one"; then
  pass 'the old server is started on port 0 for both listeners, and the rehearsal runs on the address it logs'
else
  fail 'a run'
  cat "$work/one/out" >&2
fi

# Two runs side by side.
run_behind "$work/a" &
a=$!
run_behind "$work/b" &
b=$!
if wait "$a" && wait "$b" && [ -f "$work/a/new.args" ] && [ -f "$work/b/new.args" ] \
  && [ "$(cat "$work/a/took" "$work/b/took" | tr ' ' '\n' | sort -u | wc -l)" -eq 4 ]; then
  pass 'two runs side by side each get ports of their own'
else
  fail 'two runs side by side'
  cat "$work/a/out" "$work/b/out" >&2
fi

# A port held by another process: the system never gives it.
node -e '
  const server = require("net").createServer().listen(0, "127.0.0.1", () => console.log(server.address().port));
' >"$work/held" &
holder=$!
tries=0
until [ -s "$work/held" ] || [ "$tries" -gt 50 ]; do
  tries=$((tries + 1))
  sleep 0.1
done
held=$(cat "$work/held")
if [ -n "$held" ] && run "$work/held-run" && [ -f "$work/held-run/new.args" ] && ! tr ' ' '\n' <"$work/held-run/took" | grep -qx "$held"; then
  pass "a port another process holds ($held) is not used"
else
  fail 'a port held by another process'
  cat "$work/held-run/out" >&2
fi
kill "$holder" 2>/dev/null || true
holder=''

if run "$work/broken" FAKE_BROKEN=1; then
  fail 'a server that fails'
elif [ "$(wc -l <"$work/broken/asked")" -eq 1 ] && grep -q 'the old wiki-server did not answer' "$work/broken/out" && [ ! -f "$work/broken/new.args" ]; then
  pass 'a server that fails fails the script at once, without rehearsing'
else
  fail 'a server that fails: not failed at once'
  cat "$work/broken/out" >&2
fi

# A server that never logs its address is not driven. The script gives up
# only after a minute, so the case looks for three seconds, then stops the
# script with SIGTERM: the script, not a subshell around it, ends, and its
# own cleanup stops the fake.
run_behind "$work/silent" FAKE_SILENT=1 &
silent=$!
sleep 3
if [ -f "$work/silent/asked" ] && [ ! -f "$work/silent/new.args" ] && kill -0 "$silent" 2>/dev/null; then
  pass 'a server whose log has no address is not driven'
else
  fail 'a server whose log has no address'
  cat "$work/silent/out" >&2
fi
kill "$silent" 2>/dev/null || true
wait "$silent" 2>/dev/null || true
fake=$(cat "$work/silent/pid" 2>/dev/null || true)
tries=0
while [ -n "$fake" ] && kill -0 "$fake" 2>/dev/null && [ "$tries" -lt 50 ]; do
  tries=$((tries + 1))
  sleep 0.1
done
if ! kill -0 "$silent" 2>/dev/null && [ -n "$fake" ] && ! kill -0 "$fake" 2>/dev/null; then
  pass 'the script stopped with SIGTERM ends, and stops the old server it started'
else
  fail 'the script stopped with SIGTERM: it, or the old server, still runs'
  [ -z "$fake" ] || kill "$fake" 2>/dev/null || true
fi

# The move from SQLite to PostgreSQL (--move): the old server, on SQLite,
# starts on port 0 the same way, and NEW is asked to move the copy into a
# database of the PostgreSQL the variables name, which a fake psql makes.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$FAKE_DIR/psql.log"\n' >"$work/psql"
chmod +x "$work/psql"
mode=--move
rm -f "$work/move/psql.log"
if run "$work/move" WIKI_TEST_DATABASE_URL=postgres://wiki@127.0.0.1:1/postgres WIKI_TEST_PSQL="$work/psql" \
  && asked_zero "$work/move" \
  && grep -q -- '--sqlite' "$work/move/new.args" \
  && target=$(sed -n 's|.*--move-to-database postgres://wiki@127\.0\.0\.1:1/\(wiki_test_[0-9]*_[a-z0-9]\{8\}_rehearsal_move\).*|\1|p' "$work/move/new.args") \
  && [ -n "$target" ] \
  && grep -qx -- "postgres://wiki@127.0.0.1:1/postgres --quiet --command CREATE DATABASE $target" "$work/move/psql.log" \
  && grep -qx -- "postgres://wiki@127.0.0.1:1/postgres --quiet --command DROP DATABASE IF EXISTS $target WITH (FORCE)" "$work/move/psql.log"; then
  pass 'the move rehearsal (--move) starts the old server on SQLite on port 0, asks NEW to move it into a database of the run'"'"'s own, and drops that database at the end'
else
  fail 'the move rehearsal'
  cat "$work/move/out" >&2
fi
mode=''

[ "$failures" -eq 0 ] || exit 1
