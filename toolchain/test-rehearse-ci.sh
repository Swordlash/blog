#!/bin/sh
# Regression tests of toolchain/rehearse-ci.sh's ports, against a fake OLD
# wiki-server and a fake NEW one: the two ports the old server listens on
# are below 32768, where Linux never hands out a port for an outgoing
# connection; a pair that is taken ("Address already in use") makes the
# script try another pair rather than fail; and a server that fails for
# another reason still fails the script.
#
#   sh toolchain/test-rehearse-ci.sh
#
# The fake OLD answers the few requests the script makes (a Node server on
# the admin port it is given), unless it is told to find its ports taken:
# then it says so as wiki-server does and exits. The fake NEW records its
# arguments and succeeds. Nothing but loopback is used.
set -eu
cd "$(dirname "$0")/.."
script=$(pwd)/toolchain/rehearse-ci.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf 'ok: %s\n' "$1"; }
fail() {
  printf 'FAILED: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# The fake OLD. $FAKE_BUSY is how many of its first starts find their
# ports taken; $FAKE_BROKEN makes every start fail for another reason.
# Each start's ports are logged.
cat >"$work/old" <<'EOF'
#!/bin/sh
set -eu
listen='' admin=''
while [ "$#" -gt 0 ]; do
  case $1 in
    --listen) listen=${2##*:}; shift ;;
    --admin-listen) admin=${2##*:}; shift ;;
  esac
  shift
done
printf '%s %s\n' "$listen" "$admin" >>"$FAKE_DIR/ports"
starts=$(wc -l <"$FAKE_DIR/ports")
if [ -n "${FAKE_BROKEN:-}" ]; then
  echo 'wiki-server: the database cannot be opened' >&2
  exit 1
fi
if [ "$starts" -le "${FAKE_BUSY:-0}" ]; then
  echo "wiki-server: cannot listen on 127.0.0.1:$listen: Network.Socket.bind: resource busy (Address already in use)" >&2
  exit 1
fi
exec node -e '
  const http = require("http");
  http.createServer((req, res) => {
    let made = { id: "made", homePage: "home" };
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(made));
  }).listen(Number(process.argv[1]), "127.0.0.1");
' "$admin"
EOF
cat >"$work/new" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$FAKE_DIR/new.args"
EOF
chmod +x "$work/old" "$work/new"

# Run the script with these fakes, and the settings given (FAKE_BUSY=n,
# FAKE_BROKEN=1), in a fresh directory of records.
run() {
  rm -f "$work/ports" "$work/new.args"
  env FAKE_DIR="$work" "$@" sh "$script" "$work/old" "$work/new" >"$work/out" 2>&1
}

below() {
  while read -r listen admin; do
    [ "$listen" -lt 32768 ] && [ "$admin" -lt 32768 ] && [ "$admin" -eq $((listen + 1)) ] || return 1
  done <"$work/ports"
}

if run && [ -f "$work/new.args" ] && [ "$(wc -l <"$work/ports")" -eq 1 ] && below; then
  pass 'the old server listens on two ports side by side below 32768, and the rehearsal runs'
else
  fail 'a free pair of ports'
  cat "$work/out" >&2
fi

if run FAKE_BUSY=2 && [ -f "$work/new.args" ] && [ "$(wc -l <"$work/ports")" -eq 3 ] && below \
  && [ "$(sort -u "$work/ports" | wc -l)" -eq 3 ] && grep -q 'is taken, trying another pair' "$work/out"; then
  pass 'a pair that is taken is left for another pair, each below 32768'
else
  fail 'a taken pair of ports'
  cat "$work/out" >&2
fi

if run FAKE_BUSY=20; then
  fail 'ports taken however many pairs are tried'
else
  if [ "$(wc -l <"$work/ports")" -eq 10 ] && [ ! -f "$work/new.args" ]; then
    pass 'it gives up after ten taken pairs, without rehearsing'
  else
    fail 'ports taken however many pairs are tried: not ten tries'
  fi
fi

if run FAKE_BROKEN=1; then
  fail 'a server that fails for another reason'
else
  if [ "$(wc -l <"$work/ports")" -eq 1 ] && grep -q 'the old wiki-server did not answer' "$work/out"; then
    pass 'a server that fails for another reason fails the script at once'
  else
    fail 'a server that fails for another reason: tried again'
  fi
fi

[ "$failures" -eq 0 ] || exit 1
