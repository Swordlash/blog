#!/bin/sh
# Exercise toolchain/deploy-local.sh and toolchain/undeploy-local.sh without
# touching the developer's home, systemd, firewall or toolchain: each case runs
# in a temporary $HOME with a fake repository whose bootstrap and npm build a
# tiny page, whose cabal builds a fake wiki-server (a script that logs how it
# was called, backs up by copying, and serves with Node), and fakes for
# systemctl, loginctl, ufw, sudo, tailscale and id. The fake systemctl really
# starts the unit's ExecStart line, so the server the deployment installs is
# started as systemd would start it and is fetched over HTTP. Then the static
# server's own tests run (toolchain/test-deploy-server.mjs), and the same
# cases against wiki-server (the native build's, from npm run build-native, or
# the one WIKI_SERVER names), which must serve the application as the static
# server did.
#
#   sh toolchain/test-deploy-local.sh
set -eu

SOURCE_DIR=$(cd "$(dirname "$0")" && pwd)
NODE_REAL=$(command -v node)
export NODE_REAL
# Found before the fixtures put a fake cabal first on PATH, with the cabal
# the bootstrap installed, as the npm entry points find it.
if [ -z "${WIKI_SERVER:-}" ]; then
  WIKI_SERVER=$(
    if [ -r "$HOME/.wiki-toolchain/env" ]; then
      # shellcheck source=/dev/null
      . "$HOME/.wiki-toolchain/env"
    fi
    cd "$SOURCE_DIR/.." && cabal list-bin -v0 --builddir=dist-newstyle/native wiki-server:exe:wiki-server 2>/dev/null || true
  )
fi
TMP=$(mktemp -d)
cleanup() {
  for pidfile in "$TMP"/*/systemd/*.pid; do
    if [ -f "$pidfile" ]; then kill "$(cat "$pidfile")" 2>/dev/null || true; fi
  done
  rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM
passed=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  for log in "${out:-}" "${EVENTS:-}"; do
    [ -f "$log" ] && { printf -- '--- %s\n' "$log" >&2; cat "$log" >&2; }
  done
  exit 1
}
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 lacks: $2"; }
assert_lacks() { if grep -F -- "$2" "$1" >/dev/null; then fail "$1 has: $2"; fi; }
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$*"; }
# The line number of the first line containing a string, for order checks.
line_of() { grep -n -F -- "$2" "$1" | head -n 1 | cut -d: -f1; }

# A port free on the given address, found by listening on port 0.
free_port() {
  "$NODE_REAL" -e '
    const s = require("node:net").createServer();
    s.listen(0, process.argv[1], () => { console.log(s.address().port); s.close(); });
  ' "$1"
}
# The status and media type of a GET, from the real server.
http_get() {
  "$NODE_REAL" -e '
    fetch(process.argv[1]).then(
      (r) => console.log(r.status, r.headers.get("content-type")),
      () => console.log("unreachable"),
    );
  ' "$1"
}

fixture() {
  case_dir=$TMP/$1
  mkdir -p "$case_dir/home" "$case_dir/bin" "$case_dir/sbin" "$case_dir/repo/toolchain" "$case_dir/systemd"
  for script in deploy-local.sh undeploy-local.sh deploy-lib.sh deploy-server.mjs compress.mjs; do
    cp "$SOURCE_DIR/$script" "$case_dir/repo/toolchain/"
  done
  HOME=$case_dir/home
  EVENTS=$case_dir/events
  FAKE_SYSTEMD=$case_dir/systemd
  PATH=$case_dir/bin:/usr/bin:/bin
  WIKI_DEPLOY_SBIN=$case_dir/sbin
  WIKI_DEPLOY_UFW_CONF=$case_dir/ufw.conf
  WIKI_DEPLOY_WAIT=10
  export HOME EVENTS FAKE_SYSTEMD PATH WIKI_DEPLOY_SBIN WIKI_DEPLOY_UFW_CONF WIKI_DEPLOY_WAIT
  unset XDG_CONFIG_HOME FAKE_SUDO_PASSWORD FAKE_TS_DOWN FAKE_BUILD_FAIL FAKE_NO_SYSTEMD FAKE_LINGER FAKE_BACKUP_FAIL
  printf 'ENABLED=yes\n' >"$WIKI_DEPLOY_UFW_CONF"
  : >"$EVENTS"
  # The managed Node the bootstrap installs, which the unit must name.
  mkdir -p "$HOME/.wiki-toolchain/node/bin"
  cat >"$HOME/.wiki-toolchain/node/bin/node" <<'EOF'
#!/bin/sh
exec "$NODE_REAL" "$@"
EOF
  chmod +x "$HOME/.wiki-toolchain/node/bin/node"

  # What the fake cabal builds for wiki-server: it logs how it was called,
  # backs a database up by copying it, and serves with Node, answering the
  # probes of the API and of the admin listener.
  cat >"$case_dir/fake-wiki-server" <<EOF
#!/bin/sh
printf 'wiki-server %s\n' "\$*" >>"$EVENTS"
command=\$1
shift
data= listen= admin= static=
while [ \$# -gt 0 ]; do
  case \$1 in
    --data) data=\$2; shift ;;
    --listen) listen=\$2; shift ;;
    --admin-listen) admin=\$2; shift ;;
    --static) static=\$2; shift ;;
  esac
  shift
done
case \$command in
  backup)
    [ -z "\${FAKE_BACKUP_FAIL:-}" ] || { printf 'fake backup failure\n' >&2; exit 1; }
    if [ -f "\$data/wiki.sqlite" ]; then
      mkdir -p "\$data/backups"
      cp "\$data/wiki.sqlite" "\$data/backups/\$(ls "\$data/backups" | wc -l | tr -d ' ').sqlite"
      printf 'Backed up\n'
    else
      printf 'There is no database to back up yet.\n'
    fi ;;
  serve)
    mkdir -p "\$data"
    [ -f "\$data/wiki.sqlite" ] || printf 'a database\n' >"\$data/wiki.sqlite"
    exec "$NODE_REAL" -e '
      const http = require("node:http");
      const fs = require("node:fs");
      const [listen, admin, root] = process.argv.slice(1);
      const serve = (address, api) => {
        const at = address.lastIndexOf(":");
        http.createServer((request, response) => {
          if (request.url === api) {
            response.writeHead(200, { "content-type": "application/json" }).end("{}");
          } else if (request.url === "/" || request.url === "/admin/") {
            response.writeHead(200, { "content-type": "text/html" }).end(fs.readFileSync(root + "/index.html"));
          } else {
            response.writeHead(404).end();
          }
        }).listen(Number(address.slice(at + 1)), address.slice(0, at));
      };
      serve(listen, "/api/v1/info");
      serve(admin, "/admin/api/v1/admin/status");
    ' "\$listen" "\$admin" "\$static" ;;
esac
EOF

  cat >"$case_dir/repo/toolchain/bootstrap.sh" <<'EOF'
#!/bin/sh
[ "${1:-}" = env ] && exit 0
printf 'bootstrap %s\n' "$*" >>"$EVENTS"
EOF
  cat >"$case_dir/bin/tool" <<'EOF'
#!/bin/sh
name=${0##*/}
case $name in
  id)
    case ${1:-} in
      -u) printf '1000\n' ;;
      -un) printf 'tester\n' ;;
      *) printf 'uid=1000(tester)\n' ;;
    esac ;;
  npm)
    printf 'npm %s HALOGEN_BASE_PATH=%s WIKI_BACKEND=%s\n' "$*" "${HALOGEN_BASE_PATH:-}" "${WIKI_BACKEND:-}" >>"$EVENTS"
    if [ "$1 $2" = "run build-wasm-opt" ]; then
      [ -z "${FAKE_BUILD_FAIL:-}" ] || { printf 'fake build failure\n' >&2; exit 1; }
      out=dist-newstyle/wasm-opt/public/app
      rm -rf "$out"
      mkdir -p "$out/s/blog"
      page="<!doctype html><title>wiki</title>$(printf '%2000s' '')"
      printf '%s' "$page" >"$out/index.html"
      printf '%s' "$page" >"$out/s/blog/index.html"
      printf '<!doctype html><title>missing</title>' >"$out/404.html"
      head -c 4096 /dev/zero >"$out/app.wasm"
      printf 'console.log(1);\n' >"$out/index.js"
    fi ;;
  cabal)
    printf 'cabal %s\n' "$*" >>"$EVENTS"
    bin=$PWD/dist-newstyle/native-opt/wiki-server
    case $1 in
      build)
        [ -z "${FAKE_BUILD_FAIL:-}" ] || { printf 'fake build failure\n' >&2; exit 1; }
        mkdir -p "${bin%/*}"
        cp "$FAKE_SERVER" "$bin"
        chmod +x "$bin" ;;
      list-bin) printf '%s\n' "$bin" ;;
    esac ;;
  sudo)
    if [ "${1:-}" = -n ]; then
      shift
      if [ -n "${FAKE_SUDO_PASSWORD:-}" ]; then
        printf 'sudo: a password is required\n' >&2
        exit 1
      fi
    fi
    printf 'sudo %s\n' "$*" >>"$EVENTS"
    exec "$@" ;;
  ufw)
    printf 'ufw %s\n' "$*" >>"$EVENTS"
    [ "$1" != status ] || printf 'Status: %s\n' "${FAKE_UFW_STATUS:-active}" ;;
  loginctl)
    printf 'loginctl %s\n' "$*" >>"$EVENTS"
    case $1 in
      show-user) printf 'Linger=%s\n' "${FAKE_LINGER:-no}" ;;
    esac ;;
  tailscale)
    [ -z "${FAKE_TS_DOWN:-}" ] || { printf 'failed to connect to local tailscaled\n' >&2; exit 1; }
    case $1 in
      ip) printf '127.0.0.2\n' ;;
      status) printf '{"Self":{"DNSName":"box.tail1234.ts.net."}}\n' ;;
    esac ;;
  systemctl)
    [ "$1" = --user ] || { printf 'fake systemctl: --user expected\n' >&2; exit 91; }
    shift
    printf 'systemctl %s\n' "$*" >>"$EVENTS"
    if [ -n "${FAKE_NO_SYSTEMD:-}" ]; then
      printf 'Failed to connect to bus: No medium found\n' >&2
      exit 1
    fi
    units=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
    alive() { [ -f "$FAKE_SYSTEMD/$1.pid" ] && kill -0 "$(cat "$FAKE_SYSTEMD/$1.pid")" 2>/dev/null; }
    stop() {
      if [ -f "$FAKE_SYSTEMD/$1.pid" ]; then
        pid=$(cat "$FAKE_SYSTEMD/$1.pid")
        kill "$pid" 2>/dev/null || true
        tries=0
        while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries + 1)); done
        rm -f "$FAKE_SYSTEMD/$1.pid"
      fi
    }
    start() {
      unit=$1
      line=$(sed -n 's/^ExecStart=//p' "$units/$unit")
      eval "set -- $line"
      nohup "$@" >>"$FAKE_SYSTEMD/$unit.log" 2>&1 &
      printf '%s\n' "$!" >"$FAKE_SYSTEMD/$unit.pid"
    }
    case $1 in
      show-environment) printf 'PATH=/usr/bin\n' ;;
      daemon-reload) ;;
      enable) touch "$FAKE_SYSTEMD/$2.enabled" ;;
      disable)
        [ "$2" != --now ] || { shift; stop "$2"; }
        rm -f "$FAKE_SYSTEMD/$2.enabled" ;;
      restart) stop "$2"; start "$2" ;;
      start) alive "$2" || start "$2" ;;
      stop) stop "$2" ;;
      is-active) [ "$2" != --quiet ] || shift; alive "$2" ;;
      status) if alive "$2"; then printf '%s: active (running)\n' "$2"; else printf '%s: inactive\n' "$2"; exit 3; fi ;;
      *) printf 'fake systemctl: unexpected %s\n' "$*" >&2; exit 91 ;;
    esac ;;
  *) exit 91 ;;
esac
EOF
  chmod +x "$case_dir/bin/tool"
  FAKE_SERVER=$case_dir/fake-wiki-server
  export FAKE_SERVER
  for cmd in id npm cabal sudo ufw loginctl tailscale systemctl; do
    ln -s tool "$case_dir/bin/$cmd"
  done
}

deploy() { sh "$case_dir/repo/toolchain/deploy-local.sh" "$@"; }
undeploy() { sh "$case_dir/repo/toolchain/undeploy-local.sh" "$@"; }
state() { sed -n "s/^$1=//p" "$HOME/.config/wiki-demo/${2:-wiki-demo}.state"; }
unit=.config/systemd/user/wiki-demo.service

# First install, then a re-run on another port.
fixture install
p1=$(free_port 127.0.0.2)
p2=$(free_port 127.0.0.2)
out=$case_dir/first
deploy --port "$p1" >"$out" 2>&1 || fail 'first install failed'
assert_contains "$EVENTS" 'bootstrap toolchain'
assert_contains "$EVENTS" 'npm ci --no-audit --no-fund'
assert_contains "$EVENTS" 'npm run build-wasm-opt HALOGEN_BASE_PATH=/ WIKI_BACKEND=demo'
assert_contains "$out" 'first -O2 build'
assert_contains "$HOME/$unit" "ExecStart=\"$HOME/.wiki-toolchain/node/bin/node\" \"$HOME/wiki-demo/server.mjs\" --root \"$HOME/wiki-demo/app\" --port $p1 --bind 127.0.0.2"
assert_contains "$HOME/$unit" 'Restart=on-failure'
assert_contains "$HOME/$unit" 'WantedBy=default.target'
for file in .wiki-demo-deployment server.mjs app/index.html app/404.html app/app.wasm app/app.wasm.br app/index.html.br; do
  [ -f "$HOME/wiki-demo/$file" ] || fail "missing $file"
done
[ ! -e "$HOME/wiki-demo/app/index.js.br" ] || fail 'a file under 1 KiB was compressed'
assert_contains "$EVENTS" 'systemctl daemon-reload'
assert_contains "$EVENTS" 'systemctl enable wiki-demo.service'
assert_contains "$EVENTS" 'systemctl restart wiki-demo.service'
assert_contains "$EVENTS" "ufw allow in on tailscale0 to any port $p1 proto tcp comment wiki-demo"
assert_lacks "$EVENTS" 'ufw delete'
[ "$(http_get "http://127.0.0.2:$p1/app.wasm")" = '200 application/wasm' ] || fail 'app.wasm not served'
[ "$(http_get "http://127.0.0.2:$p1/s/blog/")" = '200 text/html; charset=utf-8' ] || fail 'a prerendered route not served'
[ "$(http_get "http://127.0.0.2:$p1/s/nowhere/")" = '404 text/html; charset=utf-8' ] || fail '404.html not served'
{ [ "$(state port)" = "$p1" ] && [ "$(state bind)" = 127.0.0.2 ] && [ "$(state rule_port)" = "$p1" ]; } ||
  fail 'state does not record the deployment'
assert_contains "$out" "http://127.0.0.2:$p1/"
assert_contains "$out" "http://box.tail1234.ts.net:$p1/"
assert_contains "$out" 'journalctl --user -u wiki-demo -f'
assert_contains "$out" 'sudo loginctl enable-linger tester'
assert_lacks "$EVENTS" 'loginctl enable-linger'
assert_lacks "$EVENTS" 'cabal'
[ "$(state mode)" = static ] || fail 'state does not record the demo'
pass 'first install builds, installs, starts the service with the managed Node, opens the port on tailscale0'

: >"$EVENTS"
touch "$HOME/wiki-demo/app/stale.txt"
out=$case_dir/second
deploy --port "$p2" >"$out" 2>&1 || fail 're-run failed'
assert_lacks "$out" 'first -O2 build'
built=$(line_of "$EVENTS" 'npm run build-wasm-opt')
stopped=$(line_of "$EVENTS" 'systemctl stop wiki-demo.service')
restarted=$(line_of "$EVENTS" 'systemctl restart wiki-demo.service')
{ [ -n "$built" ] && [ -n "$stopped" ] && [ -n "$restarted" ]; } || fail 're-run did not build, stop and restart'
{ [ "$built" -lt "$stopped" ] && [ "$stopped" -lt "$restarted" ]; } || fail 'the old service was stopped before the build finished'
assert_contains "$EVENTS" "ufw delete allow in on tailscale0 to any port $p1 proto tcp"
assert_contains "$EVENTS" "ufw allow in on tailscale0 to any port $p2 proto tcp comment wiki-demo"
[ ! -e "$HOME/wiki-demo/app/stale.txt" ] || fail 'the target was not emptied'
[ "$(http_get "http://127.0.0.2:$p1/")" = unreachable ] || fail 'the old port still answers'
[ "$(http_get "http://127.0.0.2:$p2/")" = '200 text/html; charset=utf-8' ] || fail 'the new port does not answer'
{ [ "$(state port)" = "$p2" ] && [ "$(state rule_port)" = "$p2" ]; } || fail 'state not updated'
pass 're-run on a new port rebuilds, stops the old service first, moves the firewall rule and serves on the new port'

: >"$EVENTS"
out=$case_dir/no-port
deploy --no-build >"$out" 2>&1 || fail 're-run without --port failed'
assert_lacks "$EVENTS" 'npm'
assert_contains "$HOME/$unit" "--port $p2 "
assert_lacks "$EVENTS" 'ufw delete'
pass 'a re-run without options keeps the previous port; --no-build skips the build'

: >"$EVENTS"
out=$case_dir/build-fails
if FAKE_BUILD_FAIL=1 deploy --port "$p1" >"$out" 2>&1; then fail 'a failed build deployed'; fi
assert_lacks "$EVENTS" 'systemctl stop'
assert_lacks "$EVENTS" 'ufw'
[ "$(http_get "http://127.0.0.2:$p2/")" = '200 text/html; charset=utf-8' ] || fail 'a failed build took the service down'
[ "$(state port)" = "$p2" ] || fail 'a failed build changed the state'
pass 'a failed build stops before the running service or the firewall is touched'

: >"$EVENTS"
out=$case_dir/status
deploy --status >"$out" 2>&1
assert_contains "$out" "on 127.0.0.2:$p2"
assert_contains "$out" 'wiki-demo.service: active (running)'
assert_lacks "$EVENTS" 'npm'
pass '--status reports the deployment and its service without changing anything'

: >"$EVENTS"
out=$case_dir/linger
deploy --no-build --enable-linger >"$out" 2>&1 || fail '--enable-linger failed'
assert_contains "$EVENTS" 'sudo loginctl enable-linger tester'
pass '--enable-linger turns lingering on through sudo'

: >"$EVENTS"
out=$case_dir/stop
deploy --stop >"$out" 2>&1 || fail '--stop failed'
assert_contains "$EVENTS" 'systemctl disable --now wiki-demo.service'
assert_contains "$EVENTS" "ufw delete allow in on tailscale0 to any port $p2 proto tcp"
[ ! -e "$HOME/$unit" ] || fail '--stop left the unit'
[ -f "$HOME/wiki-demo/app/index.html" ] || fail '--stop deleted the files'
[ "$(http_get "http://127.0.0.2:$p2/")" = unreachable ] || fail '--stop left the server running'
{ [ -z "$(state rule_port)" ] && [ "$(state port)" = "$p2" ]; } || fail '--stop did not record the closed port'
: >"$EVENTS"
out=$case_dir/stop-again
undeploy >"$out" 2>&1 || fail 'undeploying a stopped deployment failed'
assert_lacks "$EVENTS" 'ufw'
assert_lacks "$EVENTS" 'systemctl disable'
pass '--stop disables the service, removes its unit and closes the port, keeping the files; again does nothing'

: >"$EVENTS"
out=$case_dir/purge
undeploy --purge >"$out" 2>&1 || fail 'undeploy --purge failed'
[ ! -e "$HOME/wiki-demo" ] || fail '--purge kept the files'
[ ! -e "$HOME/.config/wiki-demo/wiki-demo.state" ] || fail '--purge kept the state'
out=$case_dir/nothing
undeploy >"$out" 2>&1 || fail 'undeploying nothing failed'
assert_contains "$out" 'nothing is deployed under the name wiki-demo'
pass 'undeploy --purge deletes the marked files and the state; with nothing deployed it says so and succeeds'

# The target directory's safety checks, all before the build.
fixture unsafe
mkdir -p "$HOME/notes" "$case_dir/outside"
printf 'keep\n' >"$HOME/notes/todo.txt"
for target in "$HOME" / "$case_dir/outside" "$HOME/notes" "$HOME/.."; do
  out=$case_dir/refused
  if deploy --dir "$target" >"$out" 2>&1; then fail "deployed into $target"; fi
  assert_contains "$out" 'refusing'
done
mkdir -p "$HOME/other"
printf 'name=other\n' >"$HOME/other/.wiki-demo-deployment"
if deploy --dir "$HOME/other" >"$out" 2>&1; then fail "deployed into another deployment's directory"; fi
assert_contains "$out" 'use --name other'
[ -f "$HOME/notes/todo.txt" ] || fail 'an unmarked directory was emptied'
assert_lacks "$EVENTS" 'npm'
assert_lacks "$EVENTS" 'systemctl stop'
mkdir -p "$HOME/empty"
p=$(free_port 127.0.0.2)
deploy --dir "$HOME/empty" --port "$p" --no-firewall >"$case_dir/empty" 2>&1 || fail 'an empty directory was refused'
assert_lacks "$EVENTS" 'ufw'
undeploy >/dev/null 2>&1
pass 'refuses ~, /, directories outside ~, above it, unmarked or marked for another deployment, before building'

fixture forced
p=$(free_port 127.0.0.2)
out=$case_dir/forced
deploy --dir "$case_dir/outside" --port "$p" --force >"$out" 2>&1 || fail '--force did not allow a directory outside ~'
undeploy --purge >/dev/null 2>&1
[ ! -e "$case_dir/outside" ] || fail 'purge kept a marked directory outside ~'
pass '--force allows a directory outside ~'

# sudo that wants a password: the ufw commands are printed, not run.
fixture password
p1=$(free_port 127.0.0.2)
p2=$(free_port 127.0.0.2)
deploy --port "$p1" >"$case_dir/first" 2>&1 || fail 'first install failed'
: >"$EVENTS"
out=$case_dir/locked
FAKE_SUDO_PASSWORD=1 deploy --port "$p2" --no-build >"$out" 2>&1 || fail 'a password-protected sudo stopped the deployment'
assert_contains "$out" 'sudo needs a password, so run these yourself'
assert_contains "$out" "sudo ufw allow in on tailscale0 to any port $p2 proto tcp comment wiki-demo"
assert_contains "$out" "sudo ufw delete allow in on tailscale0 to any port $p1 proto tcp"
assert_lacks "$EVENTS" 'ufw '
[ "$(http_get "http://127.0.0.2:$p2/")" = '200 text/html; charset=utf-8' ] || fail 'not serving on the new port'
: >"$EVENTS"
out=$case_dir/undeploy-locked
FAKE_SUDO_PASSWORD=1 undeploy >"$out" 2>&1 || fail 'undeploy with a password-protected sudo failed'
assert_contains "$out" "sudo ufw delete allow in on tailscale0 to any port $p2 proto tcp"
assert_lacks "$EVENTS" 'ufw '
assert_contains "$EVENTS" 'systemctl disable --now wiki-demo.service'
printf 'ENABLED=no\n' >"$WIKI_DEPLOY_UFW_CONF"
out=$case_dir/inactive
FAKE_SUDO_PASSWORD=1 deploy --no-build >"$out" 2>&1 || fail 'deploy with inactive ufw failed'
assert_contains "$out" 'ufw is not active'
assert_lacks "$out" 'sudo ufw'
undeploy >/dev/null 2>&1
pass 'when sudo needs a password, deploy and undeploy print the exact ufw commands and go on'

fixture no-ufw
rm "$case_dir/bin/ufw"
p=$(free_port 127.0.0.2)
out=$case_dir/out
deploy --port "$p" >"$out" 2>&1 || fail 'deploy without ufw failed'
assert_contains "$out" 'ufw is not installed'
assert_lacks "$EVENTS" 'ufw'
[ -z "$(state rule_port)" ] || fail 'a rule was recorded without ufw'
undeploy >/dev/null 2>&1
pass 'without ufw the firewall is left alone'

fixture no-tailscale
p=$(free_port 127.0.0.1)
out=$case_dir/out
FAKE_TS_DOWN=1 deploy --port "$p" >"$out" 2>&1 || fail 'deploy without Tailscale failed'
assert_contains "$out" 'warning: Tailscale does not answer'
assert_contains "$HOME/$unit" '--bind 127.0.0.1'
assert_contains "$out" "http://127.0.0.1:$p/"
assert_lacks "$EVENTS" 'ufw allow'
[ "$(http_get "http://127.0.0.1:$p/")" = '200 text/html; charset=utf-8' ] || fail 'not serving on 127.0.0.1'
[ "$(state bind_choice)" = auto ] || fail 'the fallback address was recorded as chosen'
undeploy >/dev/null 2>&1
pass 'without Tailscale it listens on 127.0.0.1, warns, and opens no port'

fixture no-systemd
out=$case_dir/out
if FAKE_NO_SYSTEMD=1 deploy >"$out" 2>&1; then fail 'deployed without a systemd user instance'; fi
assert_contains "$out" 'cannot reach your systemd user instance'
assert_lacks "$EVENTS" 'npm'
pass 'without a systemd user instance it stops before building'

fixture busy
p=$(free_port 127.0.0.2)
"$NODE_REAL" -e 'require("node:net").createServer().listen(Number(process.argv[1]), "127.0.0.2")' "$p" &
holder=$!
sleep 0.5
out=$case_dir/out
if deploy --port "$p" >"$out" 2>&1; then status=deployed; else status=refused; fi
kill "$holder"
[ "$status" = refused ] || fail 'deployed on a port another program holds'
assert_contains "$out" "cannot listen on 127.0.0.2:$p"
pass 'a port another program holds is refused before anything changes'

# The wiki's server.
fixture server
p1=$(free_port 127.0.0.2)
a1=$(free_port 127.0.0.1)
data=$HOME/wiki-demo/data
out=$case_dir/first
deploy --server --port "$p1" --admin-port "$a1" >"$out" 2>&1 || fail 'the first server deploy failed'
assert_contains "$EVENTS" 'npm run build-wasm-opt HALOGEN_BASE_PATH=/ WIKI_BACKEND=server'
assert_contains "$EVENTS" 'cabal build -v0 --project-file=cabal-native-opt.project --builddir=dist-newstyle/native-opt wiki-server:exe:wiki-server'
assert_contains "$HOME/$unit" "ExecStart=\"$HOME/wiki-demo/bin/wiki-server\" serve --data \"$data\" --static \"$HOME/wiki-demo/app\" --listen 127.0.0.2:$p1 --admin-listen 127.0.0.1:$a1"
assert_lacks "$HOME/$unit" 'trust-network'
assert_contains "$HOME/$unit" 'UMask=0077'
assert_contains "$HOME/$unit" 'Description=Wiki server (wiki-demo)'
for file in .wiki-demo-deployment bin/wiki-server app/index.html app/app.wasm app/app.wasm.br data/wiki.sqlite; do
  [ -f "$HOME/wiki-demo/$file" ] || fail "missing $file"
done
[ ! -e "$HOME/wiki-demo/server.mjs" ] || fail 'the static server was installed beside wiki-server'
assert_contains "$EVENTS" "wiki-server backup --data $data"
{ [ "$(line_of "$EVENTS" 'wiki-server backup')" -lt "$(line_of "$EVENTS" 'systemctl restart wiki-demo.service')" ]; } ||
  fail 'the backup did not run before the new server started'
[ "$(http_get "http://127.0.0.2:$p1/api/v1/info")" = '200 application/json' ] || fail 'the server does not answer'
{ [ "$(state mode)" = server ] && [ "$(state admin_port)" = "$a1" ] && [ -z "$(state trust)" ]; } || fail 'state does not record the server'
assert_contains "$out" "its admin listener answers on http://127.0.0.1:$a1/admin/"
assert_contains "$out" "Administration, on this machine only: http://127.0.0.1:$a1/admin/"
assert_contains "$out" "ssh -L $a1:127.0.0.1:$a1"
assert_contains "$out" 'serves whoever signs in there'
assert_contains "$out" "users add --data $HOME/wiki-demo/data LOGIN --admin"
assert_contains "$EVENTS" "ufw allow in on tailscale0 to any port $p1 proto tcp comment wiki-demo"
assert_lacks "$EVENTS" "port $a1"
pass '--server builds wiki-server at -O2, installs it with the page, and runs it with its data and admin listener'

: >"$EVENTS"
printf 'precious\n' >>"$data/wiki.sqlite"
out=$case_dir/again
deploy --no-build --trust-network >"$out" 2>&1 || fail 'a server redeploy failed'
stopped=$(line_of "$EVENTS" 'systemctl stop wiki-demo.service')
backed=$(line_of "$EVENTS" 'wiki-server backup')
restarted=$(line_of "$EVENTS" 'systemctl restart wiki-demo.service')
{ [ -n "$stopped" ] && [ -n "$backed" ] && [ -n "$restarted" ]; } || fail 'the redeploy did not stop, back up and restart'
{ [ "$stopped" -lt "$backed" ] && [ "$backed" -lt "$restarted" ]; } || fail 'the backup was not taken between the old server and the new'
assert_contains "$data/wiki.sqlite" 'precious'
assert_contains "$data/backups/0.sqlite" 'precious'
assert_contains "$HOME/$unit" "--admin-listen 127.0.0.1:$a1 --trust-network"
assert_contains "$out" 'WARNING: --trust-network'
[ "$(state trust)" = yes ] || fail '--trust-network was not recorded'
[ "$(http_get "http://127.0.0.2:$p1/api/v1/info")" = '200 application/json' ] || fail 'the redeployed server does not answer'
pass 'a redeploy keeps data/, backs it up after stopping the old server and before the new; --trust-network reaches the unit'

: >"$EVENTS"
out=$case_dir/status
deploy --status >"$out" 2>&1
assert_contains "$out" "the wiki's server, its data in $data"
assert_contains "$out" 'backups: 1 in'
assert_contains "$out" 'everyone who reaches'
pass '--status reports the server, its data and its backups'

: >"$EVENTS"
out=$case_dir/wildcard
if deploy --no-build --bind 0.0.0.0 >"$out" 2>&1; then fail '--trust-network was deployed on 0.0.0.0'; fi
assert_contains "$out" '--trust-network with --bind 0.0.0.0'
assert_lacks "$EVENTS" 'systemctl stop'
deploy --no-build --no-trust-network >"$case_dir/untrusted" 2>&1 || fail '--no-trust-network failed'
assert_lacks "$HOME/$unit" 'trust-network'
pass '--trust-network is refused on 0.0.0.0 before anything changes, and --no-trust-network drops it'

: >"$EVENTS"
out=$case_dir/backup-fails
if FAKE_BACKUP_FAIL=1 deploy --no-build --trust-network >"$out" 2>&1; then fail 'deployed after a failed backup'; fi
assert_contains "$out" 'the backup of'
assert_contains "$EVENTS" 'systemctl start wiki-demo.service'
assert_lacks "$EVENTS" 'systemctl restart'
assert_lacks "$HOME/$unit" 'trust-network'
[ "$(http_get "http://127.0.0.2:$p1/api/v1/info")" = '200 application/json' ] || fail 'a failed backup left the old server down'
pass 'a failed backup starts the old server again and changes nothing'

: >"$EVENTS"
out=$case_dir/static
deploy --static --no-build >"$out" 2>&1 || fail 'going back to the demo failed'
assert_contains "$HOME/$unit" "/server.mjs\" --root"
assert_contains "$out" "keeping the server's data in $data"
assert_contains "$data/wiki.sqlite" 'precious'
[ ! -e "$HOME/wiki-demo/bin" ] || fail 'the server binary was left behind'
assert_lacks "$EVENTS" 'wiki-server backup'
pass '--static goes back to the demo and keeps the server data'

: >"$EVENTS"
undeploy --purge >"$case_dir/purge" 2>&1 || fail 'undeploy --purge failed'
[ "$(ls -A "$HOME/wiki-demo" | sort | tr '\n' ' ')" = '.wiki-demo-deployment data ' ] || fail "--purge left $(ls -A "$HOME/wiki-demo")"
[ ! -e "$HOME/.config/wiki-demo/wiki-demo.state" ] || fail '--purge kept the state'
assert_contains "$case_dir/purge" 'kept the wiki'"'"'s data'
p2=$(free_port 127.0.0.2)
deploy --server --no-build --port "$p2" --admin-port "$a1" >"$case_dir/back" 2>&1 || fail 'a server deploy over kept data failed'
assert_contains "$data/wiki.sqlite" 'precious'
undeploy --purge-data >"$case_dir/purge-data" 2>&1 || fail 'undeploy --purge-data failed'
[ ! -e "$HOME/wiki-demo" ] || fail '--purge-data kept the data'
pass 'undeploy --purge keeps data/ for the next deploy, and --purge-data deletes it'

fixture not-a-server
out=$case_dir/out
if deploy --trust-network >"$out" 2>&1; then fail '--trust-network deployed the demo'; fi
assert_contains "$out" 'is for the wiki'"'"'s server'
if deploy --server --port 9000 --admin-port 9000 >"$out" 2>&1; then fail 'one port for both listeners was deployed'; fi
assert_contains "$out" 'both 9000'
assert_lacks "$EVENTS" 'npm'
pass "the server's options are refused without --server, and the admin port must be another"

fixture moved
p=$(free_port 127.0.0.2)
deploy --server --port "$p" --admin-port "$(free_port 127.0.0.1)" >"$case_dir/first" 2>&1 || fail 'server deploy failed'
out=$case_dir/out
if deploy --no-build --dir "$HOME/elsewhere" >"$out" 2>&1; then fail 'moved the deployment away from its data'; fi
assert_contains "$out" "the wiki's data is in $HOME/wiki-demo/data"
undeploy --purge-data >/dev/null 2>&1
pass 'a server deployment is not moved away from its data'

printf 'Passed %s deploy regression cases.\n' "$passed"
"$NODE_REAL" "$SOURCE_DIR/test-deploy-server.mjs"
if [ -n "$WIKI_SERVER" ] && [ -x "$WIKI_SERVER" ]; then
  "$NODE_REAL" "$SOURCE_DIR/test-deploy-server.mjs" --wiki-server "$WIKI_SERVER"
else
  printf 'FAIL: no wiki-server to run the static cases against: npm run build-native, or set WIKI_SERVER\n' >&2
  exit 1
fi
