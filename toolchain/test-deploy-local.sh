#!/bin/sh
# Exercise toolchain/deploy-local.sh and toolchain/undeploy-local.sh without
# touching the developer's home, systemd, firewall or toolchain: each case runs
# in a temporary $HOME with a fake repository whose bootstrap and npm build a
# tiny page, whose cabal builds a fake wiki-server (a script that logs how it
# was called, backs up by copying a SQLite file or by running the pg_dump it
# is given, and serves with Node), and fakes for systemctl, loginctl, ufw,
# sudo, tailscale, curl, id and docker. The fake docker keeps a deployment's
# PostgreSQL container as a file that says whether it was made and is
# running, and its pg_dump writes a line that names the database. The fake systemctl
# really starts the unit's ExecStart line, so the server the deployment
# installs is started as systemd would start it and is fetched over HTTP. The
# fake tailscale keeps a serve configuration as tailscaled would, and the fake
# curl answers for its HTTPS address by fetching what that configuration
# proxies to, so the check of the HTTPS address reaches the real listener. Then the static
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
  cp "$SOURCE_DIR/../docker-compose.yml" "$case_dir/repo/"
  HOME=$case_dir/home
  EVENTS=$case_dir/events
  FAKE_SYSTEMD=$case_dir/systemd
  PATH=$case_dir/bin:/usr/bin:/bin
  WIKI_DEPLOY_SBIN=$case_dir/sbin
  WIKI_DEPLOY_UFW_CONF=$case_dir/ufw.conf
  WIKI_DEPLOY_WAIT=10
  WIKI_DEPLOY_HTTPS_WAIT=10
  FAKE_TS_SERVE=$case_dir/serve
  export HOME EVENTS FAKE_SYSTEMD PATH WIKI_DEPLOY_SBIN WIKI_DEPLOY_UFW_CONF WIKI_DEPLOY_WAIT WIKI_DEPLOY_HTTPS_WAIT FAKE_TS_SERVE
  FAKE_DOCKER=$case_dir/docker
  export FAKE_DOCKER
  mkdir -p "$FAKE_DOCKER"
  unset XDG_CONFIG_HOME FAKE_SUDO_PASSWORD FAKE_TS_DOWN FAKE_BUILD_FAIL FAKE_NO_SYSTEMD FAKE_LINGER FAKE_BACKUP_FAIL FAKE_NO_DOCKER \
    FAKE_TS_NO_OPERATOR FAKE_TS_NO_MAGICDNS FAKE_TS_NO_CERTS FAKE_TS_VERSION FAKE_TS_FUNNEL FAKE_HTTPS_DOWN FAKE_PUBLIC_URL
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
  # probes of the API and of the admin listener, and the administration's
  # server settings with the public address FAKE_PUBLIC_URL (none if unset).
  cat >"$case_dir/fake-wiki-server" <<EOF
#!/bin/sh
printf 'wiki-server %s\n' "\$*" >>"$EVENTS"
command=\$1
shift
data= listen= admin= static= sqlite= database= dump=
while [ \$# -gt 0 ]; do
  case \$1 in
    --data) data=\$2; shift ;;
    --listen) listen=\$2; shift ;;
    --admin-listen) admin=\$2; shift ;;
    --static) static=\$2; shift ;;
    --sqlite) sqlite=\$2; shift ;;
    --database) database=\$2; shift ;;
    --pg-dump) dump=\$2; shift ;;
  esac
  shift
done
case \$command in
  backup)
    [ -z "\${FAKE_BACKUP_FAIL:-}" ] || { printf 'fake backup failure\n' >&2; exit 1; }
    if [ -n "\$database" ]; then
      # As wiki-server does: pg_dump with the URL, the password elsewhere.
      mkdir -p "\$data/backups"
      "\$dump" --format=custom "--dbname=\$database" >"\$data/backups/\$(ls "\$data/backups" | wc -l | tr -d ' ').pgdump" || exit 1
      printf 'Backed up\n'
    elif grep -q 'an earlier schema' "\$data/wiki.sqlite" 2>/dev/null; then
      printf 'wiki-server: The database holds a wiki of an earlier wiki-server\n' >&2
      exit 3
    elif [ -f "\$data/wiki.sqlite" ]; then
      mkdir -p "\$data/backups"
      cp "\$data/wiki.sqlite" "\$data/backups/\$(ls "\$data/backups" | wc -l | tr -d ' ').sqlite"
      printf 'Backed up\n'
    else
      printf 'There is no database to back up yet.\n'
    fi ;;
  serve)
    mkdir -p "\$data"
    [ -z "\$sqlite" ] || [ -f "\$sqlite" ] || printf 'a database\n' >"\$sqlite"
    exec "$NODE_REAL" -e '
      const http = require("node:http");
      const fs = require("node:fs");
      const [listen, admin, root] = process.argv.slice(1);
      const serve = (address, api) => {
        const at = address.lastIndexOf(":");
        http.createServer((request, response) => {
          if (request.url === api) {
            response.writeHead(200, { "content-type": "application/json" }).end("{}");
          } else if (request.url === "/admin/api/v1/admin/server" && api.startsWith("/admin/")) {
            const publicUrl = process.env.FAKE_PUBLIC_URL || null;
            response.writeHead(200, { "content-type": "application/json" })
              .end(JSON.stringify({ publicUrl, mail: null, providers: [] }));
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
      version) printf '%s\n  tailscale commit: fake\n' "${FAKE_TS_VERSION:-1.90.1}" ;;
      status)
        if [ -n "${FAKE_TS_NO_CERTS:-}" ]; then certs=; else certs='"CertDomains":["box.tail1234.ts.net"],'; fi
        if [ -n "${FAKE_TS_NO_MAGICDNS:-}" ]; then magic=false; else magic=true; fi
        printf '{"BackendState":"Running",%s"CurrentTailnet":{"Name":"tail1234.ts.net","MagicDNSEnabled":%s},"Self":{"DNSName":"box.tail1234.ts.net."}}\n' "$certs" "$magic" ;;
      serve)
        # The serve configuration is one proxy target at https://box.../,
        # kept in FAKE_TS_SERVE; status prints it as tailscale does.
        shift
        if [ "$*" = status ]; then
          if [ -s "$FAKE_TS_SERVE" ]; then
            if [ -n "${FAKE_TS_FUNNEL:-}" ]; then reach='Funnel on'; else reach='tailnet only'; fi
            printf 'https://box.tail1234.ts.net (%s)\n|-- / proxy %s\n\n' "$reach" "$(cat "$FAKE_TS_SERVE")"
          else
            printf 'No serve config\n'
          fi
          exit 0
        fi
        printf 'tailscale serve %s\n' "$*" >>"$EVENTS"
        if [ -n "${FAKE_TS_NO_OPERATOR:-}" ]; then
          printf 'sending serve config: Access denied: serve config denied\n' >&2
          exit 1
        fi
        case $* in
          '--bg http://'*)
            printf '%s\n' "$2" >"$FAKE_TS_SERVE"
            printf 'Available within your tailnet:\n\nhttps://box.tail1234.ts.net/\n|-- proxy %s\n\nServe started and running in the background.\nTo disable the proxy, run: tailscale serve --https=443 off\n' "$2" ;;
          '--https=443 off')
            [ -s "$FAKE_TS_SERVE" ] || { printf 'error: handler does not exist\n' >&2; exit 1; }
            rm -f "$FAKE_TS_SERVE" ;;
          *) printf 'fake tailscale: unexpected serve %s\n' "$*" >&2; exit 91 ;;
        esac ;;
    esac ;;
  curl)
    # The HTTPS address answers what the serve configuration proxies to.
    for url do :; done
    printf 'curl %s\n' "$url" >>"$EVENTS"
    [ -z "${FAKE_HTTPS_DOWN:-}" ] || exit 35
    case $url in https://box.tail1234.ts.net/*) ;; *) exit 6 ;; esac
    [ -s "$FAKE_TS_SERVE" ] || exit 7
    target=$(cat "$FAKE_TS_SERVE")
    exec "$NODE_REAL" -e '
      fetch(process.argv[1]).then((r) => process.exit(r.status === 200 ? 0 : 22), () => process.exit(7));
    ' "${target%/}/${url#https://box.tail1234.ts.net/}" ;;
  docker)
    [ -z "${FAKE_NO_DOCKER:-}" ] || { printf 'failed to connect to the docker API at unix:///var/run/docker.sock\n' >&2; exit 1; }
    printf 'docker %s\n' "$*" >>"$EVENTS"
    [ "$1" != info ] || exit 0
    [ "$1" = compose ] || { printf 'fake docker: unexpected %s\n' "$*" >&2; exit 91; }
    shift
    [ "$1" != version ] || { printf 'Docker Compose version v2.40.0\n'; exit 0; }
    project=
    while [ $# -gt 0 ]; do
      case $1 in
        --project-name) project=$2; shift 2 ;;
        --file)
          [ -f "$2" ] || { printf 'fake docker: no file %s\n' "$2" >&2; exit 92; }
          shift 2 ;;
        *) break ;;
      esac
    done
    [ -s "${WIKI_DB_PASSWORD_FILE:-}" ] || { printf 'fake docker: no password file\n' >&2; exit 93; }
    container=$FAKE_DOCKER/$project
    case "$*" in
      'up --detach --wait postgres')
        if [ -f "$container" ]; then
          printf 'started on %s\n' "$WIKI_DB_PORT" >"$container"
          printf 'docker: started the container of %s\n' "$project" >>"$EVENTS"
        else
          printf 'started on %s\n' "$WIKI_DB_PORT" >"$container"
          printf 'docker: created the container and the volume of %s\n' "$project" >>"$EVENTS"
        fi ;;
      'stop postgres') [ ! -f "$container" ] || printf 'stopped\n' >"$container" ;;
      'down --volumes') rm -f "$container" ;;
      'ps postgres') cat "$container" 2>/dev/null || true ;;
      'exec -T postgres pg_dump '* | 'exec -T postgres pg_restore '*)
        grep -q '^started' "$container" 2>/dev/null || { printf 'service "postgres" is not running\n' >&2; exit 1; }
        shift 3
        printf '%s of %s:' "$1" "$project"
        shift
        printf ' %s' "$@"
        printf '\n' ;;
      *) printf 'fake docker: unexpected compose %s\n' "$*" >&2; exit 91 ;;
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
  for cmd in id npm cabal sudo ufw loginctl tailscale curl systemctl docker; do
    ln -s tool "$case_dir/bin/$cmd"
  done
}

deploy() { sh "$case_dir/repo/toolchain/deploy-local.sh" "$@"; }
undeploy() { sh "$case_dir/repo/toolchain/undeploy-local.sh" "$@"; }
state() { sed -n "s/^$1=//p" "$HOME/.config/wiki-demo/${2:-wiki-demo}.state"; }
unit=.config/systemd/user/wiki-demo.service

# A free port on 127.0.0.1 other than the one given, for a second listener.
other_port() {
  other=$(free_port 127.0.0.1)
  while [ "$other" = "$1" ]; do other=$(free_port 127.0.0.1); done
  printf '%s\n' "$other"
}
https_url=https://box.tail1234.ts.net/

# First install of the demo (--static), over HTTPS (the default), then a
# re-run on another port, which remembers the demo.
fixture install
p1=$(free_port 127.0.0.1)
p2=$(other_port "$p1")
out=$case_dir/first
deploy --static --port "$p1" >"$out" 2>&1 || fail 'first install failed'
assert_contains "$EVENTS" 'bootstrap toolchain'
assert_contains "$EVENTS" 'npm ci --no-audit --no-fund'
assert_contains "$EVENTS" 'npm run build-wasm-opt HALOGEN_BASE_PATH=/ WIKI_BACKEND=demo'
assert_contains "$out" 'first -O2 build'
assert_contains "$HOME/$unit" "ExecStart=\"$HOME/.wiki-toolchain/node/bin/node\" \"$HOME/wiki-demo/server.mjs\" --root \"$HOME/wiki-demo/app\" --port $p1 --bind 127.0.0.1"
assert_lacks "$HOME/$unit" 'secure-cookies'
assert_contains "$HOME/$unit" 'Restart=on-failure'
assert_contains "$HOME/$unit" 'WantedBy=default.target'
for file in .wiki-demo-deployment server.mjs app/index.html app/404.html app/app.wasm app/app.wasm.br app/index.html.br; do
  [ -f "$HOME/wiki-demo/$file" ] || fail "missing $file"
done
[ ! -e "$HOME/wiki-demo/app/index.js.br" ] || fail 'a file under 1 KiB was compressed'
assert_contains "$EVENTS" 'systemctl daemon-reload'
assert_contains "$EVENTS" 'systemctl enable wiki-demo.service'
assert_contains "$EVENTS" 'systemctl restart wiki-demo.service'
assert_contains "$EVENTS" "tailscale serve --bg http://127.0.0.1:$p1"
assert_lacks "$EVENTS" 'funnel'
{ [ "$(line_of "$EVENTS" 'systemctl restart wiki-demo.service')" -lt "$(line_of "$EVENTS" 'tailscale serve --bg')" ] &&
  [ "$(line_of "$EVENTS" 'tailscale serve --bg')" -lt "$(line_of "$EVENTS" "curl $https_url")" ]; } ||
  fail 'the serve was not set after the service started, and checked after'
assert_lacks "$EVENTS" 'ufw allow'
assert_lacks "$EVENTS" 'ufw delete'
[ "$(http_get "http://127.0.0.1:$p1/app.wasm")" = '200 application/wasm' ] || fail 'app.wasm not served'
[ "$(http_get "http://127.0.0.1:$p1/s/blog/")" = '200 text/html; charset=utf-8' ] || fail 'a prerendered route not served'
[ "$(http_get "http://127.0.0.1:$p1/s/nowhere/")" = '404 text/html; charset=utf-8' ] || fail '404.html not served'
[ "$(http_get "http://127.0.0.2:$p1/")" = unreachable ] || fail 'the Tailscale address is served directly'
{ [ "$(state port)" = "$p1" ] && [ "$(state bind)" = 127.0.0.1 ] && [ -z "$(state rule_port)" ] &&
  [ "$(state https)" = yes ] && [ "$(state https_host)" = box.tail1234.ts.net ] && [ "$(state serve_port)" = "$p1" ]; } ||
  fail 'state does not record the deployment'
assert_contains "$out" "it answers on $https_url"
opened=$(line_of "$out" 'Open:')
[ "$((opened + 1))" = "$(line_of "$out" "  $https_url")" ] || fail 'the HTTPS address is not the first to open'
assert_contains "$out" "  http://127.0.0.1:$p1/   (on this machine)"
assert_lacks "$out" "http://box.tail1234.ts.net:$p1/"
assert_lacks "$out" "http://127.0.0.2:$p1/"
assert_contains "$out" 'journalctl --user -u wiki-demo -f'
assert_contains "$out" 'sudo loginctl enable-linger tester'
assert_lacks "$EVENTS" 'loginctl enable-linger'
assert_lacks "$EVENTS" 'cabal'
[ "$(state mode)" = static ] || fail 'state does not record the demo'
pass 'a first install with --static builds the demo, installs it, starts the service on 127.0.0.1 with the managed Node, serves it over HTTPS through tailscale serve'

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
assert_contains "$EVENTS" "tailscale serve --bg http://127.0.0.1:$p2"
assert_lacks "$EVENTS" 'serve --https=443 off'
assert_contains "$FAKE_TS_SERVE" "http://127.0.0.1:$p2"
assert_lacks "$EVENTS" 'ufw allow'
assert_lacks "$EVENTS" 'ufw delete'
[ ! -e "$HOME/wiki-demo/app/stale.txt" ] || fail 'the target was not emptied'
[ "$(http_get "http://127.0.0.1:$p1/")" = unreachable ] || fail 'the old port still answers'
[ "$(http_get "http://127.0.0.1:$p2/")" = '200 text/html; charset=utf-8' ] || fail 'the new port does not answer'
{ [ "$(state port)" = "$p2" ] && [ "$(state serve_port)" = "$p2" ]; } || fail 'state not updated'
pass 're-run on a new port rebuilds, stops the old service first, and moves the serve to the new port'

: >"$EVENTS"
out=$case_dir/no-port
deploy --no-build >"$out" 2>&1 || fail 're-run without --port failed'
assert_lacks "$EVENTS" 'npm'
assert_contains "$HOME/$unit" "--port $p2 "
assert_lacks "$EVENTS" 'ufw delete'
assert_lacks "$EVENTS" 'tailscale serve'
assert_contains "$out" "tailscale serve already proxies $https_url to 127.0.0.1:$p2: leaving it as it is"
assert_contains "$EVENTS" "curl $https_url"
pass 'a re-run without options keeps the previous port and the serve as it is; --no-build skips the build'

# A deployment of a version before --server kept no mode in its state: it
# was the demo, and stays one, although the first run's default is now the
# server.
: >"$EVENTS"
sed -i '/^mode=/d' "$HOME/.config/wiki-demo/wiki-demo.state"
out=$case_dir/no-mode
deploy --no-build >"$out" 2>&1 || fail 're-run of a deployment without a mode failed'
assert_contains "$HOME/$unit" "/server.mjs\" --root"
assert_lacks "$EVENTS" 'cabal'
[ "$(state mode)" = static ] || fail 'a deployment without a mode did not stay the demo'
pass 'a deployment from before --server, with no mode in its state, stays the demo'

: >"$EVENTS"
out=$case_dir/build-fails
if FAKE_BUILD_FAIL=1 deploy --port "$p1" >"$out" 2>&1; then fail 'a failed build deployed'; fi
assert_lacks "$EVENTS" 'systemctl stop'
assert_lacks "$EVENTS" 'ufw'
assert_lacks "$EVENTS" 'tailscale serve'
[ "$(http_get "http://127.0.0.1:$p2/")" = '200 text/html; charset=utf-8' ] || fail 'a failed build took the service down'
[ "$(state port)" = "$p2" ] || fail 'a failed build changed the state'
pass 'a failed build stops before the running service, the firewall or the serve is touched'

: >"$EVENTS"
out=$case_dir/status
deploy --status >"$out" 2>&1
assert_contains "$out" "on 127.0.0.1:$p2"
assert_contains "$out" "HTTPS at $https_url: tailscale serve proxies it to 127.0.0.1:$p2"
assert_contains "$out" "    |-- / proxy http://127.0.0.1:$p2"
assert_contains "$out" "  $https_url"
assert_contains "$out" 'wiki-demo.service: active (running)'
assert_lacks "$EVENTS" 'npm'
pass '--status reports the deployment, its serve and its service without changing anything'

: >"$EVENTS"
out=$case_dir/linger
deploy --no-build --enable-linger >"$out" 2>&1 || fail '--enable-linger failed'
assert_contains "$EVENTS" 'sudo loginctl enable-linger tester'
pass '--enable-linger turns lingering on through sudo'

: >"$EVENTS"
out=$case_dir/stop
deploy --stop >"$out" 2>&1 || fail '--stop failed'
assert_contains "$EVENTS" 'systemctl disable --now wiki-demo.service'
assert_contains "$EVENTS" 'tailscale serve --https=443 off'
[ ! -s "$FAKE_TS_SERVE" ] || fail '--stop left the serve on'
assert_contains "$out" 'turned tailscale serve off'
assert_lacks "$EVENTS" 'ufw delete'
[ ! -e "$HOME/$unit" ] || fail '--stop left the unit'
[ -f "$HOME/wiki-demo/app/index.html" ] || fail '--stop deleted the files'
[ "$(http_get "http://127.0.0.1:$p2/")" = unreachable ] || fail '--stop left the server running'
{ [ -z "$(state serve_port)" ] && [ "$(state port)" = "$p2" ]; } || fail '--stop did not record the serve turned off'
: >"$EVENTS"
out=$case_dir/stop-again
undeploy >"$out" 2>&1 || fail 'undeploying a stopped deployment failed'
assert_lacks "$EVENTS" 'ufw'
assert_lacks "$EVENTS" 'tailscale serve'
assert_lacks "$EVENTS" 'systemctl disable'
pass '--stop disables the service, removes its unit and turns its serve off, keeping the files; again does nothing'

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
  if deploy --static --dir "$target" >"$out" 2>&1; then fail "deployed into $target"; fi
  assert_contains "$out" 'refusing'
done
mkdir -p "$HOME/other"
printf 'name=other\n' >"$HOME/other/.wiki-demo-deployment"
if deploy --static --dir "$HOME/other" >"$out" 2>&1; then fail "deployed into another deployment's directory"; fi
assert_contains "$out" 'use --name other'
[ -f "$HOME/notes/todo.txt" ] || fail 'an unmarked directory was emptied'
assert_lacks "$EVENTS" 'npm'
assert_lacks "$EVENTS" 'systemctl stop'
mkdir -p "$HOME/empty"
p=$(free_port 127.0.0.1)
deploy --static --dir "$HOME/empty" --port "$p" --no-firewall >"$case_dir/empty" 2>&1 || fail 'an empty directory was refused'
assert_lacks "$EVENTS" 'ufw'
undeploy >/dev/null 2>&1
pass 'refuses ~, /, directories outside ~, above it, unmarked or marked for another deployment, before building'

fixture forced
p=$(free_port 127.0.0.1)
out=$case_dir/forced
deploy --static --dir "$case_dir/outside" --port "$p" --force >"$out" 2>&1 || fail '--force did not allow a directory outside ~'
undeploy --purge >/dev/null 2>&1
[ ! -e "$case_dir/outside" ] || fail 'purge kept a marked directory outside ~'
pass '--force allows a directory outside ~'

# sudo that wants a password: the ufw commands are printed, not run. Over
# plain HTTP, where the Tailscale address is served and ufw has a rule to
# open.
fixture password
p1=$(free_port 127.0.0.2)
p2=$(free_port 127.0.0.2)
deploy --static --http --port "$p1" >"$case_dir/first" 2>&1 || fail 'first install failed'
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
deploy --static --http --port "$p" >"$out" 2>&1 || fail 'deploy without ufw failed'
assert_contains "$out" 'ufw is not installed'
assert_lacks "$EVENTS" 'ufw'
[ -z "$(state rule_port)" ] || fail 'a rule was recorded without ufw'
undeploy >/dev/null 2>&1
pass 'without ufw the firewall is left alone'

fixture no-tailscale
p=$(free_port 127.0.0.1)
out=$case_dir/out
FAKE_TS_DOWN=1 deploy --static --port "$p" >"$out" 2>&1 || fail 'deploy without Tailscale failed'
assert_contains "$out" 'warning: Tailscale does not answer'
assert_contains "$HOME/$unit" '--bind 127.0.0.1'
assert_contains "$out" "http://127.0.0.1:$p/"
assert_lacks "$EVENTS" 'ufw allow'
assert_lacks "$EVENTS" 'tailscale serve'
assert_lacks "$HOME/$unit" 'secure-cookies'
[ "$(http_get "http://127.0.0.1:$p/")" = '200 text/html; charset=utf-8' ] || fail 'not serving on 127.0.0.1'
[ "$(state bind_choice)" = auto ] || fail 'the fallback address was recorded as chosen'
undeploy >/dev/null 2>&1
pass 'without Tailscale it listens on 127.0.0.1, warns, and opens no port nor serve'

fixture no-systemd
out=$case_dir/out
if FAKE_NO_SYSTEMD=1 deploy >"$out" 2>&1; then fail 'deployed without a systemd user instance'; fi
assert_contains "$out" 'cannot reach your systemd user instance'
assert_lacks "$EVENTS" 'npm'
pass 'without a systemd user instance it stops before building'

fixture busy
p=$(free_port 127.0.0.1)
"$NODE_REAL" -e 'require("node:net").createServer().listen(Number(process.argv[1]), "127.0.0.1")' "$p" &
holder=$!
sleep 0.5
out=$case_dir/out
if deploy --static --port "$p" >"$out" 2>&1; then status=deployed; else status=refused; fi
kill "$holder"
[ "$status" = refused ] || fail 'deployed on a port another program holds'
assert_contains "$out" "cannot listen on 127.0.0.1:$p"
pass 'a port another program holds is refused before anything changes'

# The first run's default is the wiki's server, which the next run keeps.
fixture default
p=$(free_port 127.0.0.1)
a=$(other_port "$p")
out=$case_dir/first
deploy --port "$p" --admin-port "$a" >"$out" 2>&1 || fail 'the first install without a mode failed'
assert_contains "$EVENTS" 'npm run build-wasm-opt HALOGEN_BASE_PATH=/ WIKI_BACKEND=server'
assert_contains "$EVENTS" 'cabal build -v0 --project-file=cabal-native-opt.project --builddir=dist-newstyle/native-opt wiki-server:exe:wiki-server'
pgd=$HOME/.config/wiki-demo/wiki-demo.postgres
assert_contains "$HOME/$unit" "ExecStart=\"$HOME/wiki-demo/bin/wiki-server\" serve --data \"$HOME/wiki-demo/data\" --static \"$HOME/wiki-demo/app\" --listen 127.0.0.1:$p --admin-listen 127.0.0.1:$a --secure-cookies --database postgres://wiki@127.0.0.1:5433/wiki --database-password-file \"$pgd/db-password\" --pg-dump \"$pgd/pg_dump\" --pg-restore \"$pgd/pg_restore\""
[ ! -e "$HOME/wiki-demo/server.mjs" ] || fail 'the first install without a mode installed the demo'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the server does not answer'
[ "$(state mode)" = server ] || fail 'state does not record the server'
{ [ "$(state db)" = postgres ] && [ "$(state db_port)" = 5433 ]; } || fail 'state does not record PostgreSQL'
: >"$EVENTS"
deploy --no-build >"$case_dir/again" 2>&1 || fail 'the redeploy without a mode failed'
assert_contains "$HOME/$unit" '/bin/wiki-server" serve'
assert_contains "$HOME/$unit" '--database postgres://wiki@127.0.0.1:5433/wiki'
assert_contains "$EVENTS" 'wiki-server backup'
[ "$(state mode)" = server ] || fail 'the redeploy forgot the server'
undeploy --purge-data >/dev/null 2>&1
pass 'a first install without --server or --static deploys the server on PostgreSQL, and the next run keeps both'

# PostgreSQL in Docker (WP5.22): the first deploy makes the container, with
# its volume and a password of its own, and waits for it before the backup
# and the server; the next deploy finds it, starts it if it was stopped, and
# backs the database up with the container's pg_dump. The password is in a
# file of the owner's alone, and never in the unit, the state, the console
# or a command line.
fixture postgres
p=$(free_port 127.0.0.1)
a=$(other_port "$p")
pgd=$HOME/.config/wiki-demo/wiki-demo.postgres
data=$HOME/wiki-demo/data
out=$case_dir/first
deploy --server --port "$p" --admin-port "$a" >"$out" 2>&1 || fail 'the first deploy on PostgreSQL failed'
assert_contains "$EVENTS" 'docker: created the container and the volume of wiki-demo'
{ [ "$(line_of "$EVENTS" 'docker compose --project-name wiki-demo')" -lt "$(line_of "$EVENTS" 'wiki-server backup')" ] &&
  [ "$(line_of "$EVENTS" 'wiki-server backup')" -lt "$(line_of "$EVENTS" 'systemctl restart wiki-demo.service')" ]; } ||
  fail 'PostgreSQL did not start before the backup and the server'
assert_contains "$EVENTS" 'up --detach --wait postgres'
[ "$(stat -c %a "$pgd/db-password")" = 600 ] || fail 'the password file is not the owner'"'"'s alone'
[ "$(stat -c %a "$pgd")" = 700 ] || fail 'the PostgreSQL directory is not the owner'"'"'s alone'
password=$(cat "$pgd/db-password")
[ "${#password}" -ge 32 ] || fail 'the password is too short'
for file in "$HOME/$unit" "$HOME/.config/wiki-demo/wiki-demo.state" "$HOME/wiki-demo/bin/wiki" "$EVENTS" "$out"; do
  assert_lacks "$file" "$password"
done
assert_contains "$pgd/local.yml" '127.0.0.1:${WIKI_DB_PORT}:5432'
assert_contains "$HOME/wiki-demo/bin/wiki" "WIKI_DATABASE_URL='postgres://wiki@127.0.0.1:5433/wiki'"
assert_contains "$HOME/wiki-demo/bin/wiki" "WIKI_DATABASE_PASSWORD_FILE='$pgd/db-password'"
[ ! -e "$data/wiki.sqlite" ] || fail 'a server on PostgreSQL made data/wiki.sqlite'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the server does not answer'
assert_contains "$out" 'Its database is PostgreSQL in Docker'
pass 'the first deploy on PostgreSQL makes the container with its volume and its own password, waits for it, then backs up and starts the server'

: >"$EVENTS"
out=$case_dir/again
deploy --no-build >"$out" 2>&1 || fail 'a redeploy on PostgreSQL failed'
assert_contains "$EVENTS" 'docker: started the container of wiki-demo'
assert_lacks "$EVENTS" 'docker: created'
[ "$(cat "$pgd/db-password")" = "$password" ] || fail 'the redeploy made another password'
assert_contains "$EVENTS" "wiki-server backup --data $data --database postgres://wiki@127.0.0.1:5433/wiki --database-password-file $pgd/db-password --pg-dump $pgd/pg_dump --pg-restore $pgd/pg_restore"
# The fake server makes a dump on the first deploy too, where wiki-server
# finds no wiki yet: this one is the second.
assert_contains "$data/backups/1.pgdump" 'pg_dump of wiki-demo: --username=wiki --dbname=wiki --format=custom'
{ [ "$(line_of "$EVENTS" 'systemctl stop wiki-demo.service')" -lt "$(line_of "$EVENTS" 'wiki-server backup')" ] &&
  [ "$(line_of "$EVENTS" 'wiki-server backup')" -lt "$(line_of "$EVENTS" 'systemctl restart wiki-demo.service')" ]; } ||
  fail 'the backup was not taken between the old server and the new'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the redeployed server does not answer'
out=$case_dir/status
deploy --status >"$out" 2>&1
assert_contains "$out" 'its database: PostgreSQL in Docker, the compose project wiki-demo, on 127.0.0.1:5433'
assert_contains "$out" 'backups: 2 in'
pass 'a redeploy finds the container, backs the database up with its pg_dump between the old server and the new, and keeps the password'

# From PostgreSQL to --sqlite: the wiki would start empty in a file, so the
# deploy stops before it changes anything, unless --fresh; then the
# container is stopped with its volume kept, and --postgres (with --fresh,
# since the wiki is then in data/wiki.sqlite) goes back to it.
: >"$EVENTS"
out=$case_dir/to-sqlite
if deploy --no-build --sqlite </dev/null >"$out" 2>&1; then fail 'a deploy from PostgreSQL to --sqlite went on without --fresh'; fi
assert_contains "$out" 'the state is incompatible: this deployment kept the wiki in PostgreSQL (the volume wiki-demo_wiki-db)'
assert_contains "$out" 'run this again with --fresh'
assert_lacks "$EVENTS" 'systemctl stop'
assert_contains "$FAKE_DOCKER/wiki-demo" 'started'
assert_contains "$HOME/$unit" '--database postgres://wiki@127.0.0.1:5433/wiki'
[ "$(state db)" = postgres ] || fail 'the refused deploy changed the state'
deploy --no-build --sqlite --fresh >"$out" 2>&1 || fail 'a deploy from PostgreSQL to --sqlite --fresh failed'
assert_contains "$out" 'stopped the PostgreSQL container of wiki-demo; its data stays in the volume wiki-demo_wiki-db'
assert_contains "$FAKE_DOCKER/wiki-demo" 'stopped'
assert_contains "$HOME/$unit" "--sqlite \"$data/wiki.sqlite\""
[ "$(state db)" = sqlite ] || fail 'the state does not record SQLite'
[ ! -d "$data/replaced" ] || fail 'a directory of replaced files was made with nothing in it'
: >"$EVENTS"
deploy --no-build --postgres --fresh >"$out" 2>&1 || fail 'the deploy back to PostgreSQL failed'
assert_contains "$EVENTS" 'docker: started the container of wiki-demo'
assert_contains "$HOME/$unit" '--database postgres://wiki@127.0.0.1:5433/wiki'
find "$data/replaced" -name wiki.sqlite | grep -q . || fail 'the SQLite wiki was not kept'
pass 'a move from PostgreSQL to --sqlite is refused without --fresh, and with it stops the container and keeps its volume, which --postgres goes back to'

undeploy >"$case_dir/down" 2>&1 || fail 'the undeploy failed'
assert_contains "$case_dir/down" 'stopped the PostgreSQL container of wiki-demo; its data stays in the volume wiki-demo_wiki-db'
assert_contains "$FAKE_DOCKER/wiki-demo" 'stopped'
: >"$EVENTS"
deploy --no-build >"$case_dir/back" 2>&1 || fail 'a deploy over a stopped container failed'
assert_contains "$EVENTS" 'docker: started the container of wiki-demo'
undeploy --purge-data >"$case_dir/purged" 2>&1 || fail 'the purge failed'
assert_contains "$case_dir/purged" 'deleted the PostgreSQL container of wiki-demo and its volume wiki-demo_wiki-db'
[ ! -e "$FAKE_DOCKER/wiki-demo" ] || fail 'the container is still there'
[ ! -e "$pgd" ] || fail 'the PostgreSQL files are still there'
pass 'an undeploy stops the container and keeps its volume, a deploy starts it again, and --purge-data deletes both'

# Without Docker: the deploy on PostgreSQL stops before building, naming
# --sqlite, which deploys without it.
fixture no-docker
p=$(free_port 127.0.0.1)
a=$(other_port "$p")
out=$case_dir/refused
if FAKE_NO_DOCKER=1 deploy --server --port "$p" --admin-port "$a" >"$out" 2>&1; then fail 'a deploy on PostgreSQL went on without Docker'; fi
assert_contains "$out" 'Docker is not installed here or does not answer'
assert_contains "$out" 'or deploy with --sqlite'
assert_lacks "$EVENTS" 'npm run build-wasm-opt'
assert_lacks "$EVENTS" 'systemctl stop'
FAKE_NO_DOCKER=1 deploy --server --sqlite --port "$p" --admin-port "$a" >"$case_dir/sqlite" 2>&1 || fail 'the deploy with --sqlite failed without Docker'
assert_contains "$HOME/$unit" "--sqlite \"$HOME/wiki-demo/data/wiki.sqlite\""
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the server on SQLite does not answer'
FAKE_NO_DOCKER=1 deploy --no-build >"$case_dir/again" 2>&1 || fail 'the redeploy kept from --sqlite needed Docker'
[ "$(state db)" = sqlite ] || fail 'the redeploy forgot --sqlite'
undeploy --purge-data >/dev/null 2>&1
pass 'without Docker a deploy on PostgreSQL is refused before the build, naming --sqlite, which works and is remembered'

# A deployment of a version before PostgreSQL: its data/wiki.sqlite has the
# earlier schema. The deploy stops before the service is touched, saying the
# state is incompatible and how its content moves; --fresh moves the file
# aside, never deleting it, and starts an empty wiki on PostgreSQL.
fixture old-sqlite
p=$(free_port 127.0.0.1)
a=$(other_port "$p")
data=$HOME/wiki-demo/data
mkdir -p "$data" "$HOME/.config/wiki-demo"
printf 'name=wiki-demo\ncreated-by=toolchain/deploy-local.sh\n' >"$HOME/wiki-demo/.wiki-demo-deployment"
printf 'a wiki of an earlier schema\n' >"$data/wiki.sqlite"
printf 'name=wiki-demo\ndir=%s\nport=%s\nbind=127.0.0.1\nbind_choice=auto\nrule_port=\nmode=server\nadmin_port=%s\nhttps=no\n' \
  "$HOME/wiki-demo" "$p" "$a" >"$HOME/.config/wiki-demo/wiki-demo.state"
out=$case_dir/refused
if deploy --port "$p" --admin-port "$a" </dev/null >"$out" 2>&1; then fail 'a deploy over a wiki.sqlite of the earlier schema went on'; fi
assert_contains "$out" 'the state is incompatible'
assert_contains "$out" 'export the wiki with the running server'
assert_contains "$out" 'run this again with --fresh'
assert_lacks "$EVENTS" 'systemctl stop'
assert_lacks "$EVENTS" 'wiki-server backup'
assert_contains "$data/wiki.sqlite" 'a wiki of an earlier schema'
out=$case_dir/fresh
deploy --fresh --port "$p" --admin-port "$a" >"$out" 2>&1 || fail 'the deploy with --fresh failed'
[ ! -e "$data/wiki.sqlite" ] || fail 'data/wiki.sqlite is still where it was'
moved=$(find "$data/replaced" -name wiki.sqlite | head -n 1)
[ -n "$moved" ] || fail 'the old wiki.sqlite was not kept'
assert_contains "$moved" 'a wiki of an earlier schema'
assert_contains "$out" 'moved'
[ "$(state db)" = postgres ] || fail 'the fresh deploy is not on PostgreSQL'
[ "$(http_get "http://127.0.0.2:$p/api/v1/info")" = '200 application/json' ] || fail 'the fresh server does not answer'
undeploy --purge >/dev/null 2>&1
pass 'a data/wiki.sqlite of the earlier schema stops the deploy before anything changes; --fresh moves it aside and starts on PostgreSQL'

# With --sqlite, the backup tells the earlier schema apart (exit code 3):
# the old service goes on, and the deploy says the state is incompatible.
fixture old-schema-backup
p=$(free_port 127.0.0.1)
a=$(other_port "$p")
deploy --server --sqlite --port "$p" --admin-port "$a" >"$case_dir/first" 2>&1 || fail 'the deploy with --sqlite failed'
printf 'a wiki of an earlier schema\n' >"$HOME/wiki-demo/data/wiki.sqlite"
: >"$EVENTS"
out=$case_dir/refused
if deploy --no-build >"$out" 2>&1; then fail 'a deploy over a database the backup refused went on'; fi
assert_contains "$out" 'the state is incompatible: the database is an earlier wiki-server'"'"'s'
assert_contains "$EVENTS" 'systemctl start wiki-demo.service'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the old server was not started again'
deploy --no-build --fresh >"$case_dir/fresh" 2>&1 || fail 'the deploy with --fresh on SQLite failed'
find "$HOME/wiki-demo/data/replaced" -name wiki.sqlite | grep -q . || fail 'the old wiki.sqlite was not kept'
assert_lacks "$HOME/wiki-demo/data/wiki.sqlite" 'earlier schema'
undeploy --purge-data >/dev/null 2>&1
pass 'a backup that finds the earlier schema stops the deploy, and the old service goes on; --fresh sets the file aside'

# The wiki's server.
fixture server
p1=$(free_port 127.0.0.1)
a1=$(other_port "$p1")
data=$HOME/wiki-demo/data
out=$case_dir/first
deploy --server --sqlite --port "$p1" --admin-port "$a1" >"$out" 2>&1 || fail 'the first server deploy failed'
assert_contains "$EVENTS" 'npm run build-wasm-opt HALOGEN_BASE_PATH=/ WIKI_BACKEND=server'
assert_contains "$EVENTS" 'cabal build -v0 --project-file=cabal-native-opt.project --builddir=dist-newstyle/native-opt wiki-server:exe:wiki-server'
assert_contains "$HOME/$unit" "ExecStart=\"$HOME/wiki-demo/bin/wiki-server\" serve --data \"$data\" --static \"$HOME/wiki-demo/app\" --listen 127.0.0.1:$p1 --admin-listen 127.0.0.1:$a1 --secure-cookies --sqlite \"$data/wiki.sqlite\""
assert_lacks "$EVENTS" 'docker'
[ "$(state db)" = sqlite ] || fail 'state does not record SQLite'
assert_lacks "$HOME/$unit" 'trust-network'
assert_contains "$HOME/$unit" 'UMask=0077'
assert_contains "$HOME/$unit" 'Description=Wiki server (wiki-demo)'
for file in .wiki-demo-deployment bin/wiki-server app/index.html app/app.wasm app/app.wasm.br data/wiki.sqlite; do
  [ -f "$HOME/wiki-demo/$file" ] || fail "missing $file"
done
[ ! -e "$HOME/wiki-demo/server.mjs" ] || fail 'the static server was installed beside wiki-server'
assert_contains "$EVENTS" "wiki-server backup --data $data --sqlite $data/wiki.sqlite"
{ [ "$(line_of "$EVENTS" 'wiki-server backup')" -lt "$(line_of "$EVENTS" 'systemctl restart wiki-demo.service')" ]; } ||
  fail 'the backup did not run before the new server started'
[ "$(http_get "http://127.0.0.1:$p1/api/v1/info")" = '200 application/json' ] || fail 'the server does not answer'
{ [ "$(state mode)" = server ] && [ "$(state admin_port)" = "$a1" ] && [ -z "$(state trust)" ]; } || fail 'state does not record the server'
assert_contains "$out" "its admin listener answers on http://127.0.0.1:$a1/admin/"
assert_contains "$out" "Administration, on this machine only: http://127.0.0.1:$a1/admin/"
assert_contains "$out" "ssh -L $a1:127.0.0.1:$a1"
assert_contains "$out" 'serves whoever signs in there'
assert_contains "$out" "users add --data $HOME/wiki-demo/data LOGIN --admin"
assert_contains "$EVENTS" "tailscale serve --bg http://127.0.0.1:$p1"
assert_contains "$EVENTS" "curl ${https_url}api/v1/info"
assert_contains "$out" "it answers on ${https_url}api/v1/info"
assert_lacks "$FAKE_TS_SERVE" "$a1"
assert_lacks "$EVENTS" 'ufw allow'
assert_lacks "$EVENTS" "port $a1"
[ "$(line_of "$out" 'Open:')" -lt "$(line_of "$out" "  $https_url")" ] || fail 'the HTTPS address is not among the ones to open'
assert_contains "$out" "The wiki has no public address yet: set it to $https_url in the administration's"
assert_contains "$out" "Server section (http://127.0.0.1:$a1/admin/admin/)"
assert_contains "$HOME/wiki-demo/bin/wiki" 'unset WIKI_DATABASE_URL'
pass '--server --sqlite builds wiki-server at -O2, installs it with the page, and runs it with its data, its database in data/ and its admin listener, over HTTPS with Secure cookies'

: >"$EVENTS"
printf 'precious\n' >>"$data/wiki.sqlite"
out=$case_dir/again
deploy --no-build >"$out" 2>&1 || fail 'a server redeploy failed'
stopped=$(line_of "$EVENTS" 'systemctl stop wiki-demo.service')
backed=$(line_of "$EVENTS" 'wiki-server backup')
restarted=$(line_of "$EVENTS" 'systemctl restart wiki-demo.service')
{ [ -n "$stopped" ] && [ -n "$backed" ] && [ -n "$restarted" ]; } || fail 'the redeploy did not stop, back up and restart'
{ [ "$stopped" -lt "$backed" ] && [ "$backed" -lt "$restarted" ]; } || fail 'the backup was not taken between the old server and the new'
assert_contains "$data/wiki.sqlite" 'precious'
assert_contains "$data/backups/0.sqlite" 'precious'
[ "$(http_get "http://127.0.0.1:$p1/api/v1/info")" = '200 application/json' ] || fail 'the redeployed server does not answer'
assert_lacks "$EVENTS" 'tailscale serve'
pass 'a redeploy keeps data/, backs it up after stopping the old server and before the new'

: >"$EVENTS"
out=$case_dir/status
deploy --status >"$out" 2>&1
assert_contains "$out" "the wiki's server, its data in $data"
assert_contains "$out" 'backups: 1 in'
assert_contains "$out" "users add --data $data LOGIN --admin"
pass '--status reports the server, its data and its backups'

# The public address is the panel's: the deploy reminds of it, and says so
# when it is another than the one served.
out=$case_dir/public-http
FAKE_PUBLIC_URL="http://box.tail1234.ts.net:$p1/" deploy --no-build >"$out" 2>&1 || fail 'a redeploy with a public address failed'
assert_contains "$out" "The public address in the administration's Server section is http://box.tail1234.ts.net:$p1/, but the wiki"
assert_contains "$out" "is served at $https_url: change it there"
assert_lacks "$out" 'no public address yet'
out=$case_dir/public-https
FAKE_PUBLIC_URL=$https_url deploy --no-build >"$out" 2>&1 || fail 'a redeploy with the HTTPS public address failed'
assert_lacks "$out" 'public address yet'
assert_lacks "$out" "Server section is"
pass 'the panel'"'"'s public address is asked for when missing, pointed at when another, and left alone when the HTTPS one'

# Plain HTTP and back: --http listens on the Tailscale address without
# Secure cookies, opens the port in ufw and turns the deployment's serve
# off; HTTPS again moves back to 127.0.0.1, closing the rule.
: >"$EVENTS"
out=$case_dir/http
deploy --http --no-build >"$out" 2>&1 || fail 'the server redeploy with --http failed'
assert_contains "$HOME/$unit" "--listen 127.0.0.2:$p1 --admin-listen 127.0.0.1:$a1"
assert_lacks "$HOME/$unit" 'secure-cookies'
assert_contains "$EVENTS" 'tailscale serve --https=443 off'
[ ! -s "$FAKE_TS_SERVE" ] || fail '--http left the serve on'
assert_contains "$EVENTS" "ufw allow in on tailscale0 to any port $p1 proto tcp comment wiki-demo"
assert_lacks "$EVENTS" 'curl'
assert_contains "$out" "  http://127.0.0.2:$p1/"
assert_contains "$out" "  http://box.tail1234.ts.net:$p1/"
assert_lacks "$out" "$https_url"
{ [ "$(state https)" = no ] && [ -z "$(state serve_port)" ] && [ "$(state rule_port)" = "$p1" ]; } || fail 'state does not record plain HTTP'
[ "$(http_get "http://127.0.0.2:$p1/api/v1/info")" = '200 application/json' ] || fail 'the server does not answer on the Tailscale address'
: >"$EVENTS"
deploy --no-build >"$case_dir/http-again" 2>&1 || fail 'a redeploy over plain HTTP failed'
assert_contains "$HOME/$unit" "--listen 127.0.0.2:$p1"
assert_lacks "$EVENTS" 'tailscale serve'
deploy --status >"$case_dir/http-status" 2>&1
assert_contains "$case_dir/http-status" 'plain HTTP (--http)'
: >"$EVENTS"
out=$case_dir/https
deploy --https --no-build >"$out" 2>&1 || fail 'the server redeploy with --https failed'
assert_contains "$HOME/$unit" "--listen 127.0.0.1:$p1 --admin-listen 127.0.0.1:$a1 --secure-cookies"
assert_contains "$EVENTS" "ufw delete allow in on tailscale0 to any port $p1 proto tcp"
assert_contains "$EVENTS" "tailscale serve --bg http://127.0.0.1:$p1"
{ [ "$(state https)" = yes ] && [ "$(state serve_port)" = "$p1" ] && [ -z "$(state rule_port)" ]; } || fail 'state does not record HTTPS'
pass '--http serves the Tailscale address without Secure cookies and turns the serve off; --https moves back, deleting the ufw rule'

# A deployment of a version that trusted its network: the flag is refused,
# saying how to make an administrator instead, before anything changes; the
# next deploy drops it, and says so.
: >"$EVENTS"
printf 'trust=yes\n' >>"$HOME/.config/wiki-demo/wiki-demo.state"
for flag in --trust-network --no-trust-network; do
  out=$case_dir/trusted$flag
  if deploy --no-build "$flag" >"$out" 2>&1; then fail "$flag was taken"; fi
  assert_contains "$out" "$flag is gone"
  assert_contains "$out" 'wiki users add --data <dir>/data LOGIN --admin'
done
assert_lacks "$EVENTS" 'systemctl stop'
deploy --status >"$case_dir/trusted-status" 2>&1
assert_contains "$case_dir/trusted-status" 'it was deployed with --trust-network, which is gone'
out=$case_dir/untrusted
deploy --no-build >"$out" 2>&1 || fail 'the redeploy of a trusting deployment failed'
assert_lacks "$HOME/$unit" 'trust-network'
assert_contains "$out" "that is gone. Sign in as an administrator there, made with"
assert_contains "$out" "$HOME/wiki-demo/bin/wiki users add --data $HOME/wiki-demo/data LOGIN --admin"
[ -z "$(state trust)" ] || fail 'the state still says the network is trusted'
pass '--trust-network is refused before anything changes, pointing at the console, and a deployment that had it loses it'

: >"$EVENTS"
out=$case_dir/backup-fails
if FAKE_BACKUP_FAIL=1 deploy --no-build >"$out" 2>&1; then fail 'deployed after a failed backup'; fi
assert_contains "$out" 'the backup of'
assert_contains "$EVENTS" 'systemctl start wiki-demo.service'
assert_lacks "$EVENTS" 'systemctl restart'
[ "$(http_get "http://127.0.0.1:$p1/api/v1/info")" = '200 application/json' ] || fail 'a failed backup left the old server down'
pass 'a failed backup starts the old server again and changes nothing'

: >"$EVENTS"
out=$case_dir/static
deploy --static --no-build >"$out" 2>&1 || fail 'going back to the demo failed'
assert_contains "$HOME/$unit" "/server.mjs\" --root"
assert_contains "$HOME/$unit" "--port $p1 --bind 127.0.0.1"
assert_lacks "$HOME/$unit" 'secure-cookies'
assert_contains "$FAKE_TS_SERVE" "http://127.0.0.1:$p1"
assert_contains "$out" "  $https_url"
assert_contains "$out" "keeping the server's data in $data"
assert_contains "$data/wiki.sqlite" 'precious'
[ ! -e "$HOME/wiki-demo/bin" ] || fail 'the server binary was left behind'
assert_lacks "$EVENTS" 'wiki-server backup'
pass '--static goes back to the demo, over HTTPS without cookies, and keeps the server data'

: >"$EVENTS"
undeploy --purge >"$case_dir/purge" 2>&1 || fail 'undeploy --purge failed'
[ "$(ls -A "$HOME/wiki-demo" | sort | tr '\n' ' ')" = '.wiki-demo-deployment data ' ] || fail "--purge left $(ls -A "$HOME/wiki-demo")"
[ ! -e "$HOME/.config/wiki-demo/wiki-demo.state" ] || fail '--purge kept the state'
assert_contains "$case_dir/purge" 'kept the wiki'"'"'s data'
p2=$(other_port "$a1")
deploy --server --sqlite --no-build --port "$p2" --admin-port "$a1" >"$case_dir/back" 2>&1 || fail 'a server deploy over kept data failed'
assert_contains "$data/wiki.sqlite" 'precious'
undeploy --purge-data >"$case_dir/purge-data" 2>&1 || fail 'undeploy --purge-data failed'
[ ! -e "$HOME/wiki-demo" ] || fail '--purge-data kept the data'
pass 'undeploy --purge keeps data/ for the next deploy, and --purge-data deletes it'

# The wiki's public address, mail server and providers (WP4.4): set in the
# administration's Server section, not here. The options of earlier
# versions are refused before anything is built, pointing at the panel; a
# deployment that had them loses them, and the file of their secrets, on
# its next run, and is told what to set again.
fixture server-settings
p=$(free_port 127.0.0.1)
a=$(other_port "$p")
for args in '--smtp-host mail.example.org' '--smtp-from wiki@example.org' '--smtp-user=wiki' '--public-url https://wiki.example.org/' \
  '--oidc google=google,id.example' '--no-oidc' '--no-smtp' '--smtp-password secret' '--oidc-secret=x'; do
  out=$case_dir/refused
  # shellcheck disable=SC2086
  if deploy --server --port "$p" --admin-port "$a" $args >"$out" 2>&1; then fail "$args was taken"; fi
  assert_contains "$out" "${args%%[ =]*} is gone"
  assert_contains "$out" "the administration's Server section"
done
assert_lacks "$EVENTS" 'npm'
out=$case_dir/first
deploy --server --port "$p" --admin-port "$a" >"$out" 2>&1 || fail 'the server deploy failed'
assert_contains "$out" "http://127.0.0.1:$a/admin/admin/"
assert_contains "$out" 'oidc check --data'
assert_lacks "$HOME/$unit" 'EnvironmentFile'
pass 'the options for mail, the public address and providers are refused, pointing at the Server section'

# As an earlier version left a deployment with SMTP and a provider.
env_file=$HOME/.config/wiki-demo/wiki-demo.env
printf 'smtp_host=mail.example.org\nsmtp_port=465\nsmtp_from=Wiki <wiki@example.org>\npublic_url=https://wiki.example.org/\noidc=google=google,id.example\n' >>"$HOME/.config/wiki-demo/wiki-demo.state"
(umask 077 && printf 'WIKI_SMTP_PASSWORD="pw"\nWIKI_OIDC_GOOGLE_SECRET="s"\n' >"$env_file")
deploy --status >"$case_dir/old-status" 2>&1
assert_contains "$case_dir/old-status" 'which are gone: the next deploy drops them (mail through mail.example.org) (providers: google=google,id.example)'
out=$case_dir/upgraded
deploy --no-build >"$out" 2>&1 || fail 'the redeploy of an earlier deployment with SMTP and providers failed'
[ ! -e "$env_file" ] || fail 'the secrets of the old options were kept'
assert_contains "$out" "deleted $env_file"
assert_contains "$out" 'the public address https://wiki.example.org/'
assert_contains "$out" 'mail through mail.example.org:465, from Wiki <wiki@example.org> (and its password)'
assert_contains "$out" 'the provider google=google,id.example (and its client secret)'
assert_lacks "$HOME/$unit" 'smtp'
assert_lacks "$HOME/$unit" 'oidc'
assert_lacks "$HOME/$unit" 'EnvironmentFile'
[ -z "$(state smtp_host)$(state oidc)$(state public_url)" ] || fail 'the state still has the old options'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the upgraded server does not answer'
deploy --status >"$case_dir/status" 2>&1
assert_lacks "$case_dir/status" 'which are gone'
assert_contains "$case_dir/status" "the administration's Server section, http://127.0.0.1:$a/admin/admin/"
undeploy --purge-data >/dev/null 2>&1
pass 'a deployment with the old options loses them and their secrets, and is told what to set in the panel'

fixture not-a-server
out=$case_dir/out
if deploy --static --admin-port 9001 >"$out" 2>&1; then fail '--admin-port deployed the demo'; fi
assert_contains "$out" 'is for the wiki'"'"'s server'
if deploy --server --port 9000 --admin-port 9000 >"$out" 2>&1; then fail 'one port for both listeners was deployed'; fi
assert_contains "$out" 'both 9000'
assert_lacks "$EVENTS" 'npm'
pass "the server's options are refused without --server, and the admin port must be another"

fixture moved
p=$(free_port 127.0.0.1)
deploy --server --port "$p" --admin-port "$(other_port "$p")" >"$case_dir/first" 2>&1 || fail 'server deploy failed'
out=$case_dir/out
if deploy --no-build --dir "$HOME/elsewhere" >"$out" 2>&1; then fail 'moved the deployment away from its data'; fi
assert_contains "$out" "the wiki's data is in $HOME/wiki-demo/data"
undeploy --purge-data >/dev/null 2>&1
pass 'a server deployment is not moved away from its data'

# HTTPS through tailscale serve (WP4.18).

# A deployment of a version before HTTPS was the default: plain HTTP on the
# Tailscale address with its ufw rule, and no https in its state. Its next
# run moves it behind tailscale serve and deletes the rule.
fixture upgrade
p=$(free_port 127.0.0.2)
deploy --static --http --port "$p" >"$case_dir/first" 2>&1 || fail 'the plain HTTP deploy failed'
assert_contains "$EVENTS" "ufw allow in on tailscale0 to any port $p proto tcp comment wiki-demo"
sed -i '/^https=/d; /^https_host=/d; /^serve_port=/d' "$HOME/.config/wiki-demo/wiki-demo.state"
: >"$EVENTS"
out=$case_dir/upgraded
deploy --no-build >"$out" 2>&1 || fail 'the redeploy of an earlier plain HTTP deployment failed'
assert_contains "$EVENTS" "ufw delete allow in on tailscale0 to any port $p proto tcp"
assert_contains "$EVENTS" "tailscale serve --bg http://127.0.0.1:$p"
assert_contains "$HOME/$unit" "--port $p --bind 127.0.0.1"
[ "$(http_get "http://127.0.0.2:$p/")" = unreachable ] || fail 'the Tailscale address is still served directly'
{ [ "$(state https)" = yes ] && [ -z "$(state rule_port)" ]; } || fail 'state does not record the move to HTTPS'
undeploy >/dev/null 2>&1
pass 'a deployment from before HTTPS moves behind tailscale serve on its next run, deleting its ufw rule'

# The user is not tailscaled's operator and has no sudo: the commands are
# printed, the deploy goes on, and once the user has run them the next
# deploy finds the serve theirs.
fixture no-operator
p=$(free_port 127.0.0.1)
out=$case_dir/out
FAKE_TS_NO_OPERATOR=1 deploy --static --port "$p" >"$out" 2>&1 || fail 'a serve the user may not set stopped the deployment'
assert_contains "$EVENTS" "tailscale serve --bg http://127.0.0.1:$p"
assert_contains "$out" 'Access denied'
assert_contains "$out" "    sudo tailscale serve --bg http://127.0.0.1:$p"
assert_contains "$out" '    sudo tailscale set --operator=tester'
assert_contains "$out" "  $https_url   (once tailscale serve is set: see above)"
assert_lacks "$EVENTS" 'curl'
assert_lacks "$EVENTS" 'sudo tailscale'
[ "$(http_get "http://127.0.0.1:$p/")" = '200 text/html; charset=utf-8' ] || fail 'the deployment does not answer on 127.0.0.1'
[ "$(state serve_port)" = "$p" ] || fail 'the serve asked for is not recorded'
printf 'http://127.0.0.1:%s\n' "$p" >"$FAKE_TS_SERVE"
: >"$EVENTS"
out=$case_dir/again
FAKE_TS_NO_OPERATOR=1 deploy --no-build >"$out" 2>&1 || fail 'the redeploy after setting the serve by hand failed'
assert_contains "$out" 'tailscale serve already proxies'
assert_lacks "$EVENTS" 'tailscale serve'
assert_lacks "$out" 'once tailscale serve is set'
: >"$EVENTS"
out=$case_dir/undeploy
FAKE_TS_NO_OPERATOR=1 undeploy >"$out" 2>&1 || fail 'undeploy without operator rights failed'
assert_contains "$EVENTS" 'tailscale serve --https=443 off'
assert_contains "$out" '    sudo tailscale serve --https=443 off'
assert_contains "$out" '    sudo tailscale set --operator=tester'
pass 'a serve the user may not set is printed with the operator alternative, and the deploy and undeploy go on'

# A serve set by hand for this port is taken as the deployment's, kept, and
# turned off by the undeploy; Funnel on it is warned of, never set.
fixture adopt
p=$(free_port 127.0.0.1)
printf 'http://127.0.0.1:%s\n' "$p" >"$FAKE_TS_SERVE"
out=$case_dir/out
FAKE_TS_FUNNEL=1 deploy --static --port "$p" >"$out" 2>&1 || fail 'deploying beside a serve set by hand failed'
assert_lacks "$EVENTS" 'tailscale serve'
assert_contains "$out" "tailscale serve already proxies $https_url to 127.0.0.1:$p: leaving it as it is"
assert_contains "$out" 'Funnel is on'
assert_contains "$out" "it answers on $https_url"
: >"$EVENTS"
undeploy >"$case_dir/undeploy" 2>&1 || fail 'undeploy failed'
assert_contains "$EVENTS" 'tailscale serve --https=443 off'
[ ! -s "$FAKE_TS_SERVE" ] || fail 'the undeploy left the serve on'
pass 'a serve already proxying to the port is kept as it is, warned of under Funnel, and turned off by the undeploy'

# Something else served at https://<name>/ is left alone, by the deploy and
# by the undeploy.
fixture other-serve
p=$(free_port 127.0.0.1)
printf 'http://127.0.0.1:3000\n' >"$FAKE_TS_SERVE"
out=$case_dir/out
deploy --static --port "$p" >"$out" 2>&1 || fail 'deploying beside another serve failed'
assert_contains "$out" "$https_url already serves proxy http://127.0.0.1:3000, which this deployment did not set"
assert_contains "$out" "tailscale serve --bg http://127.0.0.1:$p (or deploy this one with --http)"
assert_lacks "$EVENTS" 'tailscale serve'
assert_contains "$FAKE_TS_SERVE" 'http://127.0.0.1:3000'
undeploy >"$case_dir/undeploy" 2>&1 || fail 'undeploy failed'
assert_lacks "$EVENTS" 'tailscale serve'
assert_contains "$FAKE_TS_SERVE" 'http://127.0.0.1:3000'
pass 'another serve at the HTTPS address is left alone by deploy and undeploy'

fixture old-tailscale
p=$(free_port 127.0.0.1)
out=$case_dir/out
FAKE_TS_VERSION=1.50.1 deploy --static --port "$p" >"$out" 2>&1 || fail 'deploying with an old Tailscale failed'
assert_contains "$out" 'this Tailscale (1.50.1) is older than 1.52'
assert_contains "$out" "    sudo tailscale serve https:443 / http://127.0.0.1:$p"
assert_lacks "$EVENTS" 'tailscale serve'
undeploy >/dev/null 2>&1
pass 'a Tailscale older than 1.52 gets the older form of the command printed, not run'

# Without MagicDNS, or without HTTPS certificates, plain HTTP as --http, and
# HTTPS again on the run that finds them.
fixture no-magicdns
p=$(free_port 127.0.0.2)
out=$case_dir/out
FAKE_TS_NO_MAGICDNS=1 deploy --static --port "$p" >"$out" 2>&1 || fail 'deploying without MagicDNS failed'
assert_contains "$out" 'warning: MagicDNS is off'
assert_contains "$out" 'https://login.tailscale.com/admin/dns'
assert_contains "$HOME/$unit" "--port $p --bind 127.0.0.2"
assert_contains "$EVENTS" "ufw allow in on tailscale0 to any port $p proto tcp comment wiki-demo"
assert_lacks "$EVENTS" 'tailscale serve'
{ [ "$(state https)" = yes ] && [ -z "$(state serve_port)" ]; } || fail 'the choice of HTTPS was not kept'
out=$case_dir/no-certs
FAKE_TS_NO_CERTS=1 deploy --no-build >"$out" 2>&1 || fail 'deploying without HTTPS certificates failed'
assert_contains "$out" 'warning: the tailnet does not issue HTTPS certificates for box.tail1234.ts.net: turn on HTTPS Certificates'
assert_lacks "$EVENTS" 'tailscale serve'
: >"$EVENTS"
deploy --no-build >"$case_dir/on" 2>&1 || fail 'deploying once MagicDNS is on failed'
assert_contains "$HOME/$unit" "--port $p --bind 127.0.0.1"
assert_contains "$EVENTS" "tailscale serve --bg http://127.0.0.1:$p"
assert_contains "$EVENTS" "ufw delete allow in on tailscale0 to any port $p proto tcp"
undeploy >/dev/null 2>&1
pass 'without MagicDNS or HTTPS certificates it serves plain HTTP and says what to turn on; the next run moves to HTTPS'

# A first certificate still on its way: a warning, not a failure.
fixture cert-pending
p=$(free_port 127.0.0.1)
out=$case_dir/out
FAKE_HTTPS_DOWN=1 WIKI_DEPLOY_HTTPS_WAIT=2 deploy --static --port "$p" >"$out" 2>&1 || fail 'an HTTPS address not answering yet failed the deploy'
assert_contains "$out" "warning: $https_url does not answer yet"
[ "$(grep -c "curl $https_url" "$EVENTS")" -ge 2 ] || fail 'the HTTPS address was not tried again'
assert_contains "$out" "  $https_url"
undeploy >/dev/null 2>&1
pass 'an HTTPS address that does not answer yet is retried, then warned of'

# Another address than 127.0.0.1 is plain HTTP.
fixture bind
p=$(free_port 127.0.0.2)
out=$case_dir/out
deploy --static --bind 0.0.0.0 --port "$p" >"$out" 2>&1 || fail 'deploying on 0.0.0.0 failed'
assert_contains "$out" '--bind 0.0.0.0 implies --http'
assert_lacks "$EVENTS" 'tailscale serve'
[ "$(state https)" = no ] || fail '--bind 0.0.0.0 was recorded as HTTPS'
out=$case_dir/refused
if deploy --no-build --https --bind 127.0.0.2 >"$out" 2>&1; then fail '--https was taken with another address'; fi
assert_contains "$out" '--https serves from 127.0.0.1 behind tailscale serve'
# Another port: the one on 0.0.0.0 holds 127.0.0.1 too until it stops.
p2=$(other_port "$p")
: >"$EVENTS"
out=$case_dir/https
deploy --no-build --https --port "$p2" >"$out" 2>&1 || fail '--https after an explicit --bind failed'
assert_contains "$HOME/$unit" "--port $p2 --bind 127.0.0.1"
assert_contains "$EVENTS" "tailscale serve --bg http://127.0.0.1:$p2"
undeploy >/dev/null 2>&1
pass '--bind with another address than 127.0.0.1 implies --http; --https drops a remembered one'

printf 'Passed %s deploy regression cases.\n' "$passed"
"$NODE_REAL" "$SOURCE_DIR/test-deploy-server.mjs"
if [ -n "$WIKI_SERVER" ] && [ -x "$WIKI_SERVER" ]; then
  "$NODE_REAL" "$SOURCE_DIR/test-deploy-server.mjs" --wiki-server "$WIKI_SERVER"
else
  printf 'FAIL: no wiki-server to run the static cases against: npm run build-native, or set WIKI_SERVER\n' >&2
  exit 1
fi
