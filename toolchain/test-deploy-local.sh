#!/bin/sh
# Exercise toolchain/deploy-local.sh and toolchain/undeploy-local.sh without
# touching the developer's home, systemd, firewall or toolchain: each case runs
# in a temporary $HOME with a fake repository whose bootstrap and npm build a
# tiny page, whose cabal builds a fake wiki-server (a script that logs how it
# was called, backs up by copying a SQLite file or by running the pg_dump it
# is given, and serves with Node, over HTTPS when given a certificate), and fakes for systemctl, loginctl, ufw,
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
# server did. The configuration wizard is checked here too: its options
# against the deploy's header, and its wrapper, toolchain/configure.sh,
# with the fakes. With WIKI_TEST_WIZARD=1 and cabal on PATH, it first runs
# toolchain/test-configure.sh as well, which compiles the wizard (brick and
# vty: minutes the first time) and checks the command lines it builds; npm
# run test-native leaves that out.
#
#   sh toolchain/test-deploy-local.sh
#   WIKI_TEST_WIZARD=1 sh toolchain/test-deploy-local.sh
set -eu

SOURCE_DIR=$(cd "$(dirname "$0")" && pwd)
NODE_REAL=$(command -v node)
# The wizard's command lines, which take GHC, cabal and a compiled brick:
# only when asked for (WIKI_TEST_WIZARD=1) and cabal is on PATH. They run
# first, before the fixtures change HOME, PATH and cabal's directory, so
# that cabal finds its package index and store.
if [ "${WIKI_TEST_WIZARD:-}" = 1 ]; then
  if command -v cabal >/dev/null 2>&1; then
    sh "$SOURCE_DIR/test-configure.sh"
  else
    printf 'FAIL: WIKI_TEST_WIZARD=1, but cabal is not on PATH to build the wizard with (. ~/.wiki-toolchain/env)\n' >&2
    exit 1
  fi
fi
export NODE_REAL
# Found before the fixtures put a fake cabal first on PATH, with the cabal
# the bootstrap installed, as the npm entry points find it.
if [ -z "${WIKI_SERVER:-}" ]; then
  WIKI_SERVER=$(
    toolchain_home=${WIKI_TOOLCHAIN_HOME:-$HOME}
    if [ -r "$toolchain_home/.wiki-toolchain/env" ]; then
      # shellcheck source=/dev/null
      . "$toolchain_home/.wiki-toolchain/env"
    fi
    cd "$SOURCE_DIR/.." && cabal list-bin -v0 --builddir=dist-newstyle/native wiki-server:exe:wiki-server 2>/dev/null || true
  )
fi
# The PATH for the test of the real toolchain/check-semaphore.sh, with the
# toolchain's environment loaded as the deploy loads it, so that its ghc is
# the bootstrap's. Taken before the fixtures put their fakes first on PATH.
REAL_PATH=$(
  toolchain_home=${WIKI_TOOLCHAIN_HOME:-$HOME}
  if [ -r "$toolchain_home/.wiki-toolchain/env" ]; then
    # shellcheck source=/dev/null
    . "$toolchain_home/.wiki-toolchain/env"
  fi
  printf '%s' "$PATH"
)
TMP=$(mktemp -d)
cleanup() {
  for pidfile in "$TMP"/*/systemd/*.pid; do
    if [ -f "$pidfile" ]; then kill "$(cat "$pidfile")" 2>/dev/null || true; fi
  done
  rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM
passed=0
# The commands of /usr/bin and /bin but dpkg-query, as links, for the cases
# of a machine that is not Debian: the deploy lets the bootstrap install
# what toolchain/check-native.sh finds missing when dpkg-query is on PATH,
# and the host's own (GitHub's runner has one) would be found through
# /usr/bin. Those cases run with PATH=$case_dir/bin:$NO_DPKG.
NO_DPKG=$TMP/no-dpkg
mkdir "$NO_DPKG"
for cmd in /usr/bin/* /bin/*; do
  name=${cmd##*/}
  [ "$name" != dpkg-query ] || continue
  if [ ! -f "$cmd" ] || [ ! -x "$cmd" ]; then continue; fi
  [ -e "$NO_DPKG/$name" ] || [ -L "$NO_DPKG/$name" ] || ln -s "$cmd" "$NO_DPKG/$name"
done

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
  for script in deploy-local.sh undeploy-local.sh deploy-lib.sh deploy-server.mjs compress.mjs check-native.sh configure.sh; do
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
  # cabal's own directory, where its build logs go (logs/ghc-<version>/).
  CABAL_DIR=$case_dir/cabal
  export CABAL_DIR
  mkdir -p "$FAKE_DOCKER"
  unset XDG_CONFIG_HOME XDG_CACHE_HOME FAKE_NO_LIBSODIUM FAKE_NO_TINFO FAKE_NO_ZLIB FAKE_BOOTSTRAP_ZLIB FAKE_CABAL_NO_LIBRARY FAKE_CABAL_SEMOPEN FAKE_SEMAPHORE PKG_CONFIG_PATH LIBRARY_PATH C_INCLUDE_PATH CPATH LD_LIBRARY_PATH FAKE_GITHUB FAKE_SUDO_PASSWORD FAKE_TS_DOWN FAKE_BUILD_FAIL FAKE_NO_SYSTEMD FAKE_LINGER FAKE_BACKUP_FAIL FAKE_NO_DOCKER \
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
  # With --tls-cert and --tls-key its public listener speaks HTTPS with
  # them, as wiki-server's does.
  cat >"$case_dir/fake-wiki-server" <<EOF
#!/bin/sh
printf 'wiki-server %s\n' "\$*" >>"$EVENTS"
command=\$1
shift
target=\${1:-}
data= listen= admin= static= sqlite= database= dump= cert= key=
while [ \$# -gt 0 ]; do
  case \$1 in
    --data) data=\$2; shift ;;
    --tls-cert) cert=\$2; shift ;;
    --tls-key) key=\$2; shift ;;
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
  compress)
    # As wiki-server compress does: a gzip copy of each file over 1 KiB
    # with one of the extensions toolchain/compress.mjs is given.
    written=0
    for file in \$(find "\$target" -type f \( -name '*.wasm' -o -name '*.js' -o -name '*.mjs' -o -name '*.css' -o -name '*.html' -o -name '*.svg' -o -name '*.json' \) -size +1k); do
      gzip -9 -k -f "\$file"
      written=\$((written + 1))
    done
    printf 'Wrote %s gzip copies in %s.\n' "\$written" "\$target" ;;
  guide)
    [ -z "\${FAKE_GUIDE_FAIL:-}" ] || { printf 'fake guide failure\n' >&2; exit 1; }
    printf "The guide's pages have this release's text (5 pages).\n" ;;
  serve)
    mkdir -p "\$data"
    [ -z "\$sqlite" ] || [ -f "\$sqlite" ] || printf 'a database\n' >"\$sqlite"
    exec "$NODE_REAL" -e '
      const http = require("node:http");
      const https = require("node:https");
      const fs = require("node:fs");
      const [listen, admin, root, cert, key] = process.argv.slice(1);
      const serve = (address, api, tls) => {
        const at = address.lastIndexOf(":");
        const create = tls
          ? (handler) => https.createServer({ cert: fs.readFileSync(cert), key: fs.readFileSync(key) }, handler)
          : (handler) => http.createServer(handler);
        create((request, response) => {
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
      serve(listen, "/api/v1/info", Boolean(cert));
      serve(admin, "/admin/api/v1/admin/status", false);
    ' "\$listen" "\$admin" "\$static" "\$cert" "\$key" ;;
esac
EOF

  # The bootstrap: it says how it was called and where the toolchain goes,
  # and installs the managed Node (but in its native mode, which installs
  # none) and the environment file there, as the real one does under
  # WIKI_TOOLCHAIN_HOME. Its native mode ends, as the real one's does, with
  # toolchain/check-native.sh, given the options after the mode, and stops
  # when something is missing.
  cat >"$case_dir/repo/toolchain/bootstrap.sh" <<'EOF'
#!/bin/sh
[ "${1:-}" = env ] && exit 0
printf 'bootstrap %s WIKI_TOOLCHAIN_HOME=%s\n' "$*" "${WIKI_TOOLCHAIN_HOME:-}" >>"$EVENTS"
# As the bootstrap installs zlib1g-dev on Debian: the file
# FAKE_BOOTSTRAP_ZLIB names makes the fake pkg-config find zlib.
[ -z "${FAKE_BOOTSTRAP_ZLIB:-}" ] || : >"$FAKE_BOOTSTRAP_ZLIB"
base=${WIKI_TOOLCHAIN_HOME:-$HOME}
mkdir -p "$base/.wiki-toolchain"
if [ "${1:-}" != native ]; then
  mkdir -p "$base/.wiki-toolchain/node/bin"
  printf '#!/bin/sh\nexec "$NODE_REAL" "$@"\n' >"$base/.wiki-toolchain/node/bin/node"
  chmod +x "$base/.wiki-toolchain/node/bin/node"
fi
: >"$base/.wiki-toolchain/env"
if [ "${1:-}" = native ]; then
  shift
  if ! check_output=$(sh "$(dirname "$0")/check-native.sh" "$@" 2>&1); then
    printf '%s\nbootstrap: the native build of wiki-server needs what is missing above\n' "$check_output" >&2
    exit 1
  fi
fi
EOF
  # The probe of cabal's build semaphore (toolchain/check-semaphore.sh): it
  # says that it ran, and exits with FAKE_SEMAPHORE, 0 (the semaphore works)
  # when unset, 1 (GHC cannot open it) or 2 (the probe could not run), with
  # what the real one prints in each case.
  cat >"$case_dir/repo/toolchain/check-semaphore.sh" <<'EOF'
#!/bin/sh
printf 'check-semaphore\n' >>"$EVENTS"
case ${FAKE_SEMAPHORE:-0} in
  0) printf 'semaphore ok\n' ;;
  1) printf 'wiki_semaphore_probe_1: semOpen: does not exist (No such file or directory)\n' >&2; exit 1 ;;
  *) printf 'check-semaphore: no ghc (ghc) to run the probe\n' >&2; exit 2 ;;
esac
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
    printf 'npm %s HALOGEN_BASE_PATH=%s WIKI_BACKEND=%s WIKI_TOOLCHAIN_HOME=%s\n' "$*" "${HALOGEN_BASE_PATH:-}" "${WIKI_BACKEND:-}" "${WIKI_TOOLCHAIN_HOME:-}" >>"$EVENTS"
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
        printf 'cabal build PKG_CONFIG_PATH=%s LIBRARY_PATH=%s C_INCLUDE_PATH=%s\n' "${PKG_CONFIG_PATH:-}" "${LIBRARY_PATH:-}" "${C_INCLUDE_PATH:-}" >>"$EVENTS"
        if [ -n "${FAKE_CABAL_NO_LIBRARY:-}" ]; then
          printf "Error: The pkg-config package 'libsodium' is required but it could not be found.\n" >&2
          exit 1
        fi
        if [ -n "${FAKE_CABAL_SEMOPEN:-}" ]; then
          # As on the RHEL server: a dependency's build fails in its log,
          # and the console only points at it.
          mkdir -p "$CABAL_DIR/logs/ghc-9.14.1"
          for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32; do
            printf 'Building library line %s\n' "$i"
          done >"$CABAL_DIR/logs/ghc-9.14.1/splitmix-0.1.3.1-abc123.log"
          printf 'cabal_semaphore_y: semOpen: does not exist (no such file or directory)\n' >>"$CABAL_DIR/logs/ghc-9.14.1/splitmix-0.1.3.1-abc123.log"
          printf 'Error: [Cabal-7125]\nFailed to build splitmix-0.1.3.1. See the build log above for details.\n' >&2
          exit 1
        fi
        # A line of the progress cabal shows, which the deploy must let through.
        printf 'Building executable wiki-server for wiki-server-0.1.0.0 (the fake cabal)\n'
        mkdir -p "${bin%/*}"
        cp "$FAKE_SERVER" "$bin"
        chmod +x "$bin" ;;
      list-bin) printf '%s\n' "$bin" ;;
    esac ;;
  pkg-config)
    # libpq and zlib are found, zlib unless FAKE_NO_ZLIB hides it and the
    # fake bootstrap has not written FAKE_BOOTSTRAP_ZLIB. libsodium
    # is found unless FAKE_NO_LIBSODIUM hides the system's and
    # PKG_CONFIG_PATH names no directory with its libsodium.pc; that one's
    # libdir and includedir are those of the prefix it is under.
    case $* in
      '--exists libpq') exit 0 ;;
      '--exists zlib') [ -z "${FAKE_NO_ZLIB:-}" ] || [ -f "${FAKE_BOOTSTRAP_ZLIB:-/nowhere}" ] ;;
      '--exists libsodium')
        [ -z "${FAKE_NO_LIBSODIUM:-}" ] || [ -f "${PKG_CONFIG_PATH:-/nowhere}/libsodium.pc" ] ;;
      '--variable=libdir libsodium') printf '%s\n' "${PKG_CONFIG_PATH%/pkgconfig}" ;;
      '--variable=includedir libsodium') printf '%s\n' "${PKG_CONFIG_PATH%/lib/pkgconfig}/include" ;;
      *) exit 1 ;;
    esac ;;
  pg_config) printf '/usr/lib/postgresql/17/bin\n' ;;
  cc)
    # The preprocessor finds every header (gmp.h). A link with -lsodium,
    # the probe of toolchain/check-native.sh, writes its program, unless
    # FAKE_NO_LIBSODIUM hides the system's libsodium and LIBRARY_PATH and
    # C_INCLUDE_PATH name no directories with libsodium.a and sodium.h. A
    # link with -ltinfo, the wizard's probe, fails with FAKE_NO_TINFO.
    output= sodium= tinfo=
    while [ $# -gt 0 ]; do
      case $1 in
        -o) output=$2; shift ;;
        -lsodium) sodium=1 ;;
        -ltinfo) tinfo=1 ;;
      esac
      shift
    done
    if [ -z "$output" ]; then cat >/dev/null; exit 0; fi
    if [ -n "$tinfo" ] && [ -n "${FAKE_NO_TINFO:-}" ]; then
      printf 'ld: cannot find -ltinfo\n' >&2
      exit 1
    fi
    if [ -n "$sodium" ] && [ -n "${FAKE_NO_LIBSODIUM:-}" ] &&
      ! { [ -f "${LIBRARY_PATH:-/nowhere}/libsodium.a" ] && [ -f "${C_INCLUDE_PATH:-/nowhere}/sodium.h" ]; }; then
      printf 'ld: cannot find -lsodium\n' >&2
      exit 1
    fi
    printf '#!/bin/sh\n' >"$output"
    chmod +x "$output" ;;
  make) ;;
  dpkg-query) printf 'install ok installed\n' ;;
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
    # GitHub, as FAKE_GITHUB holds it (releases/<tag>.json, and the assets
    # under download/<tag>/), and the listeners on this machine, which a
    # deployment without Node probes with curl: with -o, -w '%{http_code}'
    # and -f as curl reads them.
    output='' format='' failing='' cacert='' connect='' insecure=''
    while [ $# -gt 1 ]; do
      case $1 in
        -o) output=$2; shift ;;
        -w) format=$2; shift ;;
        --cacert) cacert=$2; shift ;;
        --connect-to) connect=$2; shift ;;
        --insecure) insecure=1 ;;
        --*) ;;
        -*f*) failing=1 ;;
      esac
      shift
    done
    case $url in
      https://api.github.com/repos/Owner/blog/releases/tags/*)
        release=$FAKE_GITHUB/releases/${url##*/}.json
        if [ -f "$release" ]; then code=200; else code=404; release=/dev/null; fi
        if [ -n "$output" ]; then cat "$release" >"$output"; else cat "$release"; fi
        [ -z "$format" ] || printf '%s' "$code"
        exit 0 ;;
      https://github.com/Owner/blog/releases/download/*)
        asset=$FAKE_GITHUB/download/${url#https://github.com/Owner/blog/releases/download/}
        [ -f "$asset" ] || exit 22
        cp "$asset" "$output"
        exit 0 ;;
      # The server's own HTTPS listener, as curl reaches it: checking its
      # certificate against --cacert, for the URL's name reached at the
      # address --connect-to gives, or not at all with --insecure.
      https://127.*:* | https://*.test:*)
        printf 'curl-tls %s cacert=%s connect=%s insecure=%s\n' "$url" "$cacert" "$connect" "$insecure" >>"$EVENTS"
        exec "$NODE_REAL" -e '
          const [url, output, format, failing, cacert, connect, insecure] = process.argv.slice(1);
          const target = new URL(url);
          const [name, , host, port] = connect ? connect.split(":") : [];
          const request = require("node:https").get({
            host: host ?? target.hostname, port: port ?? target.port, path: target.pathname,
            servername: name ?? target.hostname, rejectUnauthorized: !insecure,
            ca: cacert ? require("node:fs").readFileSync(cacert) : undefined,
          }, (r) => {
            const chunks = [];
            r.on("data", (c) => chunks.push(c)).on("end", () => {
              if (failing && r.statusCode >= 400) process.exit(22);
              if (output && output !== "/dev/null") require("node:fs").writeFileSync(output, Buffer.concat(chunks));
              if (format) process.stdout.write(String(r.statusCode));
              process.exit(0);
            });
          });
          request.on("error", (e) => { process.stderr.write("curl: (60) " + e.message + "\n"); if (format) process.stdout.write("000"); process.exit(60); });
        ' "$url" "$output" "$format" "$failing" "$cacert" "$connect" "$insecure" ;;
      http://127.0.0.1:* | 'http://[::1]:'*)
        exec "$NODE_REAL" -e '
          const [url, output, format, failing] = process.argv.slice(1);
          fetch(url).then(async (r) => {
            const body = Buffer.from(await r.arrayBuffer());
            if (failing && r.status >= 400) process.exit(22);
            if (output) require("node:fs").writeFileSync(output, body); else process.stdout.write(body);
            if (format) process.stdout.write(String(r.status));
          }, () => { if (format) process.stdout.write("000"); process.exit(7); });
        ' "$url" "$output" "$format" "$failing" ;;
    esac
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
  for cmd in id npm cabal sudo ufw loginctl tailscale curl systemctl docker pkg-config pg_config cc make; do
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
assert_contains "$EVENTS" 'bootstrap build WIKI_TOOLCHAIN_HOME='
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
mkdir -p "$HOME/notes"
printf 'keep\n' >"$HOME/notes/todo.txt"
for target in "$HOME" / "$HOME/notes" "$HOME/.." "$case_dir/repo"; do
  out=$case_dir/refused
  if deploy --static --prefix "$target" >"$out" 2>&1; then fail "deployed into $target"; fi
  case $target in
    "$case_dir/repo"*) assert_contains "$out" 'the checkout' ;;
    *) assert_contains "$out" 'refusing' ;;
  esac
done
mkdir -p "$HOME/other"
printf 'name=other\n' >"$HOME/other/.wiki-demo-deployment"
if deploy --static --prefix "$HOME/other" >"$out" 2>&1; then fail "deployed into another deployment's directory"; fi
assert_contains "$out" 'use --name other'
[ -f "$HOME/notes/todo.txt" ] || fail 'an unmarked directory was emptied'
[ ! -e "$HOME/notes/.wiki-demo-deployment" ] || fail 'an unmarked directory was claimed'
assert_lacks "$EVENTS" 'npm'
assert_lacks "$EVENTS" 'systemctl stop'
mkdir -p "$HOME/empty"
p=$(free_port 127.0.0.1)
deploy --static --prefix "$HOME/empty" --port "$p" --no-firewall >"$case_dir/empty" 2>&1 || fail 'an empty directory was refused'
assert_lacks "$EVENTS" 'ufw'
undeploy --prefix "$HOME/empty" >/dev/null 2>&1
pass 'refuses ~, /, directories above ~, unmarked or marked for another deployment, and the checkout, before building'

# A deployment under a prefix, outside the home directory (WP5.48): the
# server on SQLite, everywhere on the network, on a user without sudo.
fixture prefix
p=$(free_port 127.0.0.1)
a=$(other_port "$p")
pre=$case_dir/srv/wiki
out=$case_dir/first
deploy --server --sqlite --prefix "$pre" --port "$p" --admin-port "$a" --bind 0.0.0.0 --no-firewall >"$out" 2>&1 || fail 'the deploy under a prefix failed'
# A wiki in SQLite: the bootstrap's build mode asks Debian for no libpq-dev.
assert_contains "$EVENTS" "bootstrap build --without-postgres WIKI_TOOLCHAIN_HOME=$pre/toolchain"
assert_contains "$EVENTS" "npm run build-wasm-opt HALOGEN_BASE_PATH=/ WIKI_BACKEND=server WIKI_TOOLCHAIN_HOME=$pre/toolchain"
for file in .wiki-demo-deployment bin/wiki-server bin/wiki app/index.html state/wiki-demo.state toolchain/.wiki-toolchain/node/bin/node; do
  [ -e "$pre/$file" ] || fail "missing $file under the prefix"
done
assert_contains "$HOME/$unit" "ExecStart=\"$pre/bin/wiki-server\" serve --data \"$pre/data\" --static \"$pre/app\" --listen 0.0.0.0:$p --admin-listen 127.0.0.1:$a --sqlite \"$pre/data/wiki.sqlite\""
[ ! -e "$HOME/wiki-demo" ] || fail 'the deployment went to the home directory'
[ ! -e "$HOME/.config/wiki-demo" ] || fail 'the state went to the home directory'
[ "$(ls -A "$HOME" | sort | tr '\n' ' ')" = '.config .wiki-toolchain ' ] || fail "the home directory holds more than the unit: $(ls -A "$HOME" | tr '\n' ' ')"
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the server under the prefix does not answer'
[ "$(sed -n 's/^toolchain=//p' "$pre/state/wiki-demo.state")" = "$pre/toolchain" ] || fail 'the state does not record the toolchain'
assert_contains "$out" "--status --name wiki-demo --prefix $pre"
assert_contains "$out" "The toolchain the build used is under $pre/toolchain"
pass 'a deployment under a prefix outside ~ puts its files, state and toolchain there, and nothing in ~ but the unit'

: >"$EVENTS"
touch "$pre/toolchain/kept" "$pre/app/stale"
out=$case_dir/again
deploy --prefix "$pre" --no-build >"$out" 2>&1 || fail 'the redeploy under the prefix failed'
[ -e "$pre/toolchain/kept" ] || fail 'the redeploy emptied the toolchain'
[ ! -e "$pre/app/stale" ] || fail 'the redeploy did not empty the page'
[ -f "$pre/state/wiki-demo.state" ] || fail 'the redeploy lost the state'
assert_contains "$HOME/$unit" "--listen 0.0.0.0:$p "
assert_lacks "$EVENTS" 'bootstrap'
pass 'a redeploy under the prefix keeps the toolchain and the state, and remembers the options'

out=$case_dir/stopped
deploy --prefix "$pre" --stop >"$out" 2>&1 || fail '--stop under the prefix failed'
[ "$(sed -n 's/^toolchain=//p' "$pre/state/wiki-demo.state")" = "$pre/toolchain" ] || fail '--stop forgot the toolchain'
deploy --prefix "$pre" --no-build >"$case_dir/restarted" 2>&1 || fail 'the redeploy after --stop failed'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the server did not come back after --stop'
out=$case_dir/inside
if deploy --prefix "$pre" --toolchain "$pre/tools" --no-build >"$out" 2>&1; then fail 'a toolchain inside the prefix was accepted'; fi
assert_contains "$out" "put it at $pre/toolchain, or outside $pre"
pass '--stop keeps the toolchain choice, and a toolchain inside the prefix other than toolchain/ is refused'

out=$case_dir/no-prefix
if deploy --status >"$out" 2>&1; then fail '--status without the prefix went on'; fi
assert_contains "$out" "the deployment wiki-demo is under $pre: run this with --prefix $pre"
if deploy --no-build >"$out" 2>&1; then fail 'a deploy without the prefix went on'; fi
assert_contains "$out" "run this with --prefix $pre, or deploy this one under another --name"
deploy --status --prefix "$pre" >"$out" 2>&1
assert_contains "$out" "on 0.0.0.0:$p; its toolchain under $pre/toolchain"
if undeploy >"$out" 2>&1; then fail 'undeploy without the prefix went on'; fi
assert_contains "$out" "run this with --prefix $pre"
[ -f "$HOME/$unit" ] || fail 'undeploy without the prefix removed the unit'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'undeploy without the prefix took the server down'
undeploy --name other >"$out" 2>&1 || fail 'undeploying a name nobody deployed failed'
assert_contains "$out" 'nothing is deployed under the name other: a deployment under a prefix is found with --prefix DIR'
pass 'without --prefix, a deploy, --status and undeploy stop at the unit and say what to give'

: >"$EVENTS"
out=$case_dir/old-name
deploy --dir "$pre" --no-build >"$out" 2>&1 || fail '--dir, the old name of --prefix, failed'
assert_lacks "$out" 'first -O2 build'
pass '--dir is accepted as the old name of --prefix'

out=$case_dir/purged
undeploy --prefix "$pre" --purge >"$out" 2>&1 || fail 'undeploy --purge under the prefix failed'
[ -d "$pre/data" ] || fail '--purge deleted the data'
[ ! -e "$pre/toolchain" ] && [ ! -e "$pre/bin" ] && [ ! -e "$pre/state" ] || fail '--purge kept the toolchain, the state or the files'
[ ! -e "$HOME/$unit" ] || fail '--purge kept the unit'
assert_contains "$out" 'and the toolchain under it'
pass 'undeploy --purge under the prefix deletes the toolchain and the state too, and keeps the data'

# A deployment stopped without --purge keeps its state and loses its unit;
# another of the same name made elsewhere meanwhile owns the unit, and a run
# for the stopped one must not take it.
fixture two-prefixes
p=$(free_port 127.0.0.1)
deploy --static --prefix "$case_dir/a" --port "$p" --no-firewall >"$case_dir/a-first" 2>&1 || fail 'the deployment at a failed'
deploy --prefix "$case_dir/a" --stop >"$case_dir/a-stop" 2>&1 || fail 'stopping a failed'
[ -f "$case_dir/a/state/wiki-demo.state" ] || fail 'the stopped deployment lost its state'
deploy --static --prefix "$case_dir/b" --port "$p" --no-firewall >"$case_dir/b-first" 2>&1 || fail 'the deployment at b failed'
: >"$EVENTS"
out=$case_dir/a-undeploy
if undeploy --prefix "$case_dir/a" >"$out" 2>&1; then fail "undeploying the stopped deployment took b's unit"; fi
assert_contains "$out" "the deployment wiki-demo is under $case_dir/b: run this with --prefix $case_dir/b"
out=$case_dir/a-redeploy
if deploy --prefix "$case_dir/a" --no-build >"$out" 2>&1; then fail "redeploying the stopped deployment took b's unit"; fi
assert_contains "$out" "run this with --prefix $case_dir/b, or deploy this one under another --name"
assert_lacks "$EVENTS" 'systemctl'
[ "$(http_get "http://127.0.0.1:$p/")" = '200 text/html; charset=utf-8' ] || fail 'b went down'
out=$case_dir/home-run
if deploy --no-build >"$out" 2>&1; then fail "a run in the home directory took b's unit"; fi
assert_contains "$out" "the deployment wiki-demo is under $case_dir/b"
undeploy --prefix "$case_dir/b" >/dev/null 2>&1
out=$case_dir/home-unit
deploy --static --port "$p" --no-firewall >"$case_dir/home-first" 2>&1 || fail 'the home deployment failed'
if deploy --prefix "$case_dir/a" --no-build >"$out" 2>&1; then fail "a run under a prefix took the home deployment's unit"; fi
assert_contains "$out" 'the deployment wiki-demo is in the home directory (its unit names no prefix): run this without --prefix'
undeploy >/dev/null 2>&1
pass "a run for a stopped deployment does not take the unit of another deployment of the name, under another prefix or in the home directory"

# A deployment made before --prefix, in the home directory, is adopted when
# named by --prefix: its state moves under it and its toolchain stays home.
fixture adopted
p=$(free_port 127.0.0.1)
a=$(other_port "$p")
deploy --server --sqlite --port "$p" --admin-port "$a" --no-firewall >"$case_dir/first" 2>&1 || fail 'the home deployment failed'
[ -f "$HOME/.config/wiki-demo/wiki-demo.state" ] || fail 'the home deployment kept no state in the home directory'
out=$case_dir/status-before
deploy --status --prefix "$HOME/wiki-demo" >"$out" 2>&1
assert_contains "$out" "on 127.0.0.1:$p"
[ -f "$HOME/.config/wiki-demo/wiki-demo.state" ] || fail '--status moved the state'
: >"$EVENTS"
out=$case_dir/build-fails
if FAKE_BUILD_FAIL=1 deploy --prefix "$HOME/wiki-demo" >"$out" 2>&1; then fail 'a failed build adopted'; fi
[ -f "$HOME/.config/wiki-demo/wiki-demo.state" ] || fail 'a failed build moved the state'
: >"$EVENTS"
out=$case_dir/adopted
deploy --prefix "$HOME/wiki-demo" --no-build >"$out" 2>&1 || fail 'adopting the home deployment failed'
assert_contains "$out" "adopting wiki-demo: its state moves from $HOME/.config/wiki-demo to $HOME/wiki-demo/state"
[ ! -e "$HOME/.config/wiki-demo/wiki-demo.state" ] || fail 'the state stayed in the home directory'
[ -f "$HOME/wiki-demo/state/wiki-demo.state" ] || fail 'the state did not move under the prefix'
[ "$(sed -n 's/^toolchain=//p' "$HOME/wiki-demo/state/wiki-demo.state")" = "$HOME" ] || fail 'the adopted deployment moved its toolchain'
assert_contains "$HOME/$unit" "--listen 127.0.0.1:$p "
assert_contains "$HOME/$unit" "# Prefix: $HOME/wiki-demo"
: >"$EVENTS"
deploy --prefix "$HOME/wiki-demo" >"$case_dir/rebuilt" 2>&1 || fail 'rebuilding the adopted deployment failed'
assert_contains "$EVENTS" 'bootstrap build --without-postgres WIKI_TOOLCHAIN_HOME=
'
[ "$(sed -n 's/^toolchain=//p' "$HOME/wiki-demo/state/wiki-demo.state")" = "$HOME" ] || fail 'the rebuild forgot the toolchain choice'
: >"$EVENTS"
out=$case_dir/elsewhere
if deploy --prefix "$HOME/elsewhere" --no-build >"$out" 2>&1; then fail 'a second deployment of the name was made elsewhere'; fi
assert_contains "$out" "the deployment wiki-demo is under $HOME/wiki-demo: run this with --prefix $HOME/wiki-demo, or deploy this one under another --name"
assert_lacks "$EVENTS" 'systemctl stop'
undeploy --prefix "$HOME/wiki-demo" >/dev/null 2>&1
pass 'a deployment made in the home directory is adopted by a deploy with --prefix, keeping its state, port and toolchain'

# The same on PostgreSQL: the password and the compose files are copied
# under the prefix and the old ones go once the new unit names the copies;
# --purge keeps the password with the volume it belongs to.
fixture adopted-postgres
p=$(free_port 127.0.0.1)
a=$(other_port "$p")
deploy --server --port "$p" --admin-port "$a" --no-firewall >"$case_dir/first" 2>&1 || fail 'the home deployment on PostgreSQL failed'
old_pgd=$HOME/.config/wiki-demo/wiki-demo.postgres
password=$(cat "$old_pgd/db-password")
out=$case_dir/adopted
deploy --prefix "$HOME/wiki-demo" --no-build >"$out" 2>&1 || fail 'adopting on PostgreSQL failed'
pgd=$HOME/wiki-demo/state/wiki-demo.postgres
[ "$(cat "$pgd/db-password")" = "$password" ] || fail 'the password did not come along'
[ "$(stat -c %a "$pgd/db-password")" = 600 ] || fail 'the copied password is not the owner'"'"'s alone'
[ ! -e "$old_pgd" ] || fail 'the old PostgreSQL files stayed'
assert_contains "$HOME/$unit" "--database-password-file \"$pgd/db-password\""
assert_contains "$HOME/wiki-demo/bin/wiki" "WIKI_DATABASE_PASSWORD_FILE='$pgd/db-password'"
assert_contains "$pgd/pg_dump" "$pgd/docker-compose.yml"
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the adopted server does not answer'
out=$case_dir/purged
undeploy --prefix "$HOME/wiki-demo" --purge >"$out" 2>&1 || fail 'undeploy --purge on PostgreSQL failed'
[ "$(cat "$pgd/db-password")" = "$password" ] || fail '--purge deleted the password of the volume kept'
[ -f "$FAKE_DOCKER/wiki-demo" ] || fail '--purge deleted the volume'
[ -d "$HOME/wiki-demo/data" ] || fail '--purge deleted the data'
[ ! -e "$HOME/wiki-demo/bin" ] && [ ! -e "$HOME/wiki-demo/state/wiki-demo.state" ] || fail '--purge kept the files or the state'
assert_contains "$out" "and the password of the database in $pgd, with the volume wiki-demo_wiki-db"
pass 'adoption on PostgreSQL copies the database files under the prefix and --purge keeps the password with the volume'

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
assert_contains "$EVENTS" 'cabal build --project-file=cabal-native-opt.project --builddir=dist-newstyle/native-opt wiki-server:exe:wiki-server'
# A wiki in PostgreSQL: wiki-server is built with it, the bootstrap is not
# told to leave libpq out, and libpq is checked.
assert_contains "$EVENTS" 'bootstrap build WIKI_TOOLCHAIN_HOME='
assert_lacks "$EVENTS" 'without-postgres'
assert_contains "$EVENTS" 'wiki-server:exe:wiki-server --constraint=wiki-server +postgres'
assert_lacks "$EVENTS" 'wiki-server -postgres'
assert_contains "$out" 'ok       libpq       pg_config at'
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
assert_contains "$EVENTS" "wiki-server guide update --data $data --database postgres://wiki@127.0.0.1:5433/wiki --database-password-file $pgd/db-password"
{ [ "$(line_of "$EVENTS" 'systemctl restart wiki-demo.service')" -lt "$(line_of "$EVENTS" 'wiki-server guide update')" ]; } ||
  fail 'the guide was updated before the new server started'
out=$case_dir/status
deploy --status >"$out" 2>&1
assert_contains "$out" 'its database: PostgreSQL in Docker, the compose project wiki-demo, on 127.0.0.1:5433'
assert_contains "$out" 'backups: 2 in'
pass 'a redeploy finds the container, backs the database up with its pg_dump between the old server and the new, keeps the password, and updates the guide on the new server'

: >"$EVENTS"
out=$case_dir/guide-fails
FAKE_GUIDE_FAIL=1 deploy --no-build >"$out" 2>&1 || fail 'a failed update of the guide failed the deploy'
assert_contains "$out" "the guide's pages could not be updated"
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'a failed update of the guide left the server down'
pass 'a failed update of the guide is a warning, and the new server stays'

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
assert_contains "$EVENTS" 'cabal build --project-file=cabal-native-opt.project --builddir=dist-newstyle/native-opt wiki-server:exe:wiki-server'
assert_contains "$EVENTS" 'cabal list-bin --project-file=cabal-native-opt.project'
# The probe found the semaphore usable, so the build uses it, and the probe
# ran before the build.
assert_contains "$out" 'build semaphore: ok, cabal and GHC share one job budget'
assert_contains "$EVENTS" 'wiki-server -postgres --semaphore'
[ "$(line_of "$EVENTS" 'check-semaphore')" -lt "$(line_of "$EVENTS" 'cabal build')" ] ||
  fail 'the semaphore was not probed before the build'
# cabal's output is shown while it builds, after the deploy's line for it.
assert_contains "$out" 'Building executable wiki-server for wiki-server-0.1.0.0 (the fake cabal)'
[ "$(line_of "$out" 'building wiki-server at -O2')" -lt "$(line_of "$out" 'Building executable wiki-server')" ] ||
  fail "cabal's output did not come after the deploy's line for the build"
# A wiki in SQLite: wiki-server is built without PostgreSQL, for the build
# and for list-bin alike, and the check does not ask for libpq.
assert_contains "$EVENTS" 'cabal build --project-file=cabal-native-opt.project --builddir=dist-newstyle/native-opt wiki-server:exe:wiki-server --constraint=wiki-server -postgres'
assert_contains "$EVENTS" 'cabal list-bin --project-file=cabal-native-opt.project --builddir=dist-newstyle/native-opt wiki-server:exe:wiki-server --constraint=wiki-server -postgres -v0'
assert_lacks "$EVENTS" 'wiki-server +postgres'
assert_contains "$out" 'skipped  libpq       not needed (built without PostgreSQL)'
assert_lacks "$out" 'ok       libpq'
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
assert_contains "$EVENTS" "wiki-server guide update --data $data --sqlite $data/wiki.sqlite"
{ [ "$(line_of "$EVENTS" 'systemctl restart wiki-demo.service')" -lt "$(line_of "$EVENTS" 'wiki-server guide update')" ]; } ||
  fail 'the guide was updated before the new server started'
assert_contains "$out" "bringing the guide's pages up to this version"
pass '--server --sqlite builds wiki-server at -O2, showing cabal'"'"'s output, installs it with the page, and runs it with its data, its database in data/ and its admin listener, over HTTPS with Secure cookies, then updates the guide'

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
if deploy --no-build --prefix "$HOME/elsewhere" >"$out" 2>&1; then fail 'moved the deployment away from its data'; fi
assert_contains "$out" "the wiki's data in $HOME/wiki-demo/data: deploy it there with --prefix $HOME/wiki-demo"
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
sed -i '/^https=/d; /^https_host=/d; /^serve_port=/d; /^way=/d; /^tls_/d' "$HOME/.config/wiki-demo/wiki-demo.state"
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

# toolchain/check-native.sh alone, with the fixture's fakes: everything is
# there, then zlib is not. And a server deploy that builds the page here
# runs it before anything else, so a machine without zlib's development
# files and without dpkg-query is refused before the bootstrap, npm or
# cabal runs.
fixture native-deps
out=$case_dir/check
sh "$case_dir/repo/toolchain/check-native.sh" >"$out" 2>&1 || fail 'the check failed with everything there'
[ "$(grep -c '^ok ' "$out")" = 9 ] || fail 'the check did not report nine items ok'
assert_contains "$out" 'ok       zlib        pkg-config --exists zlib'
assert_contains "$out" 'ok       libsodium   sodium.h and -lsodium, through cc'
assert_contains "$out" 'All 9 items the native build of wiki-server needs are there.'
out=$case_dir/check-no-zlib
status=0
FAKE_NO_ZLIB=1 sh "$case_dir/repo/toolchain/check-native.sh" >"$out" 2>&1 || status=$?
[ "$status" = 1 ] || fail "the check without zlib exited $status, not 1"
assert_contains "$out" 'missing  zlib        pkg-config --exists zlib failed (Debian: zlib1g-dev; RHEL: zlib-devel)'
assert_contains "$out" 'Missing for the native build of wiki-server: zlib.'
assert_contains "$out" 'sudo apt-get install zlib1g-dev'
assert_contains "$out" 'sudo dnf install zlib-devel'
assert_contains "$out" 'LIBRARY_PATH, C_INCLUDE_PATH, CPATH'
assert_contains "$out" 'LD_LIBRARY_PATH'
[ "$(grep -c '^ok ' "$out")" = 8 ] || fail 'the check without zlib did not report the other eight items ok'
pass 'toolchain/check-native.sh reports each item ok, and names a missing one with its packages and exits 1'

# libpq is found through pg_config on PATH, which postgresql-libpq's build
# runs: pkg-config's libpq alone is not enough. These runs get a PATH of the
# fakes and links to the host's commands, without pg_config on either, and
# WIKI_PG_CONFIG_DIRS in place of /usr/pgsql-*/bin and
# /usr/lib/postgresql/*/bin, so that the host's PostgreSQL is not seen.
no_pg=$case_dir/no-pg
mkdir "$no_pg"
for cmd in /usr/bin/* /bin/*; do
  name=${cmd##*/}
  [ "$name" != pg_config ] || continue
  if [ ! -f "$cmd" ] || [ ! -x "$cmd" ]; then continue; fi
  [ -e "$no_pg/$name" ] || [ -L "$no_pg/$name" ] || ln -s "$cmd" "$no_pg/$name"
done
rm "$case_dir/bin/pg_config"
out=$case_dir/check-no-pg-config
status=0
WIKI_PG_CONFIG_DIRS=$case_dir/nowhere env PATH="$case_dir/bin:$no_pg" sh "$case_dir/repo/toolchain/check-native.sh" >"$out" 2>&1 || status=$?
[ "$status" = 1 ] || fail "the check without pg_config exited $status, not 1"
assert_contains "$out" 'missing  libpq       no pg_config on PATH, though pkg-config knows libpq: the build runs pg_config (Debian: libpq-dev; RHEL: libpq-devel)'
assert_contains "$out" 'postgresql-libpq runs pg_config when cabal builds it, so pg_config must be on PATH.'
assert_contains "$out" "PGDG's postgresqlNN-devel, which puts it in /usr/pgsql-NN/bin"
assert_contains "$out" "PATH=/usr/pgsql-NN/bin:\$PATH sh toolchain/deploy-local.sh"
[ "$(grep -c '^ok ' "$out")" = 8 ] || fail 'the check without pg_config did not report the other eight items ok'
mkdir -p "$case_dir/pgsql-16/bin"
ln -s "$case_dir/bin/tool" "$case_dir/pgsql-16/bin/pg_config"
out=$case_dir/check-pg-config-elsewhere
status=0
WIKI_PG_CONFIG_DIRS="$case_dir/nowhere $case_dir/pgsql-*/bin" env PATH="$case_dir/bin:$no_pg" sh "$case_dir/repo/toolchain/check-native.sh" >"$out" 2>&1 || status=$?
[ "$status" = 1 ] || fail "the check with pg_config off PATH exited $status, not 1"
assert_contains "$out" "missing  libpq       no pg_config on PATH, but there is one at $case_dir/pgsql-16/bin/pg_config"
assert_contains "$out" "There is one at $case_dir/pgsql-16/bin/pg_config: put its directory on PATH for the deploy:"
assert_contains "$out" "PATH=$case_dir/pgsql-16/bin:\$PATH sh toolchain/deploy-local.sh"
out=$case_dir/check-pg-config-on-path
env PATH="$case_dir/pgsql-16/bin:$case_dir/bin:$no_pg" sh "$case_dir/repo/toolchain/check-native.sh" >"$out" 2>&1 ||
  fail 'the check failed with that pg_config on PATH'
assert_contains "$out" "ok       libpq       pg_config at $case_dir/pgsql-16/bin/pg_config, headers in"
ln -s tool "$case_dir/bin/pg_config"
pass 'toolchain/check-native.sh takes libpq only from a pg_config on PATH, not from pkg-config alone, and names a pg_config off PATH to put on it'

# For a build without PostgreSQL, libpq is not needed: its line says so and
# is not counted.
out=$case_dir/check-without-postgres
sh "$case_dir/repo/toolchain/check-native.sh" --without-postgres >"$out" 2>&1 ||
  fail 'the check --without-postgres failed with everything there'
assert_contains "$out" 'skipped  libpq       not needed (built without PostgreSQL)'
assert_contains "$out" 'All 8 items the native build of wiki-server needs are there.'
[ "$(grep -c '^ok ' "$out")" = 8 ] || fail 'the check --without-postgres did not report eight items ok'
assert_lacks "$out" 'missing'
status=0
sh "$case_dir/repo/toolchain/check-native.sh" --postgres >"$out" 2>&1 || status=$?
[ "$status" = 2 ] || fail "the check with an unknown option exited $status, not 2"
pass 'toolchain/check-native.sh --without-postgres reports libpq as not needed, and does not count it'

# toolchain/check-semaphore.sh itself, the real one, with the real cc and
# ghc: on this machine GHC can open the semaphore. Then with a fake ghc
# that fails on -jsem with the RHEL server's error and compiles without it,
# with one that fails either way, and without a ghc or a C compiler.
fixture semaphore-probe
probe() { env PATH="$1" sh "$SOURCE_DIR/check-semaphore.sh"; }
mkdir -p "$case_dir/jsem-fails" "$case_dir/ghc-fails"
cat >"$case_dir/jsem-fails/ghc" <<'EOF'
#!/bin/sh
case " $* " in
  *" -jsem "*)
    printf 'cabal_semaphore_x: semOpen: does not exist (No such file or directory)\n' >&2
    exit 1 ;;
esac
EOF
printf '#!/bin/sh\nprintf "ghc: cannot find the base package\\n" >&2\nexit 1\n' >"$case_dir/ghc-fails/ghc"
chmod +x "$case_dir/jsem-fails/ghc" "$case_dir/ghc-fails/ghc"
out=$case_dir/out
status=0
WIKI_GHC=$case_dir/nowhere/ghc probe "$REAL_PATH" >"$out" 2>&1 || status=$?
[ "$status" = 2 ] || fail "the probe without a ghc exited $status, not 2"
assert_contains "$out" "check-semaphore: no ghc ($case_dir/nowhere/ghc) to run the probe"
status=0
CC=$case_dir/nowhere/cc probe "$REAL_PATH" >"$out" 2>&1 || status=$?
[ "$status" = 2 ] || fail "the probe without a C compiler exited $status, not 2"
assert_contains "$out" "check-semaphore: no C compiler ($case_dir/nowhere/cc) to build the probe"
if env PATH="$REAL_PATH" sh -c 'command -v cc && command -v ghc' >/dev/null 2>&1; then
  probe "$REAL_PATH" >"$out" 2>&1 || fail "the probe found no semaphore on this machine: $(cat "$out")"
  [ "$(cat "$out")" = 'semaphore ok' ] || fail "the probe printed more than semaphore ok"
  status=0
  probe "$case_dir/jsem-fails:$REAL_PATH" >"$out" 2>&1 || status=$?
  [ "$status" = 1 ] || fail "the probe with a ghc that cannot open the semaphore exited $status, not 1"
  assert_contains "$out" 'cabal_semaphore_x: semOpen: does not exist (No such file or directory)'
  status=0
  probe "$case_dir/ghc-fails:$REAL_PATH" >"$out" 2>&1 || status=$?
  [ "$status" = 2 ] || fail "the probe with a ghc that fails without the semaphore too exited $status, not 2"
  assert_contains "$out" 'fails on a one-line module even without the semaphore:'
  assert_contains "$out" 'ghc: cannot find the base package'
  pass 'toolchain/check-semaphore.sh finds the semaphore usable here, reports GHC'"'"'s semOpen error with 1, and exits 2 when it cannot run'
else
  printf 'note: no cc or no ghc on PATH, so the real toolchain/check-semaphore.sh was tested only without them\n'
  pass 'toolchain/check-semaphore.sh exits 2 without a ghc or a C compiler'
fi

p=$(free_port 127.0.0.1)
a=$(other_port "$p")
out=$case_dir/no-zlib
if FAKE_NO_ZLIB=1 PATH=$case_dir/bin:$NO_DPKG deploy --server --sqlite --port "$p" --admin-port "$a" >"$out" 2>&1; then
  fail 'a machine without zlib deployed'
fi
assert_contains "$out" 'missing  zlib'
assert_contains "$out" 'the native build of wiki-server needs what is missing above; nothing was changed'
assert_lacks "$out" 'warning: missing for the native build'
assert_lacks "$EVENTS" 'bootstrap'
assert_lacks "$EVENTS" 'npm'
assert_lacks "$EVENTS" 'cabal'
assert_lacks "$EVENTS" 'systemctl stop'
assert_lacks "$EVENTS" 'systemctl restart'
: >"$EVENTS"
out=$case_dir/static
deploy --static --port "$p" >"$out" 2>&1 || fail 'the demo was refused for want of zlib'
assert_lacks "$out" 'check-native.sh'
undeploy >/dev/null 2>&1
pass 'a server deploy that builds the page here checks the native build first and stops without zlib; the demo builds no wiki-server and is not checked'

# On Debian or Ubuntu (a dpkg-query on PATH) the bootstrap installs the
# missing packages: the deploy warns and goes on, and checks again after
# the bootstrap. A bootstrap that leaves zlib missing stops the deploy
# there, before npm or cabal; one that installs it lets the deploy go on.
ln -s tool "$case_dir/bin/dpkg-query"
: >"$EVENTS"
out=$case_dir/debian-no-zlib
if FAKE_NO_ZLIB=1 deploy --server --sqlite --port "$p" --admin-port "$a" >"$out" 2>&1; then
  fail 'a Debian machine whose bootstrap left zlib missing deployed'
fi
assert_contains "$out" 'missing  zlib'
assert_contains "$out" 'warning: missing for the native build of wiki-server: zlib; the bootstrap installs the Debian packages next, and the check runs again after it'
assert_contains "$EVENTS" 'bootstrap build'
assert_contains "$out" 'the native build of wiki-server still needs what is missing above; nothing was changed'
[ "$(line_of "$out" 'warning: missing for the native build')" -lt "$(line_of "$out" 'checking again what the native build')" ] ||
  fail 'the check after the bootstrap came before the warning'
assert_lacks "$EVENTS" 'npm'
assert_lacks "$EVENTS" 'cabal'
: >"$EVENTS"
out=$case_dir/debian-zlib-installed
FAKE_NO_ZLIB=1 FAKE_BOOTSTRAP_ZLIB=$case_dir/zlib-installed deploy --server --sqlite --port "$p" --admin-port "$a" >"$out" 2>&1 ||
  fail 'a Debian machine whose bootstrap installed zlib did not deploy'
assert_contains "$out" 'warning: missing for the native build of wiki-server: zlib'
assert_contains "$out" 'checking again what the native build of wiki-server needs, after the bootstrap'
# The check after the bootstrap is told, as the first was, that a wiki in
# SQLite needs no libpq: eight items.
assert_contains "$out" 'All 8 items the native build of wiki-server needs are there.'
assert_contains "$EVENTS" 'bootstrap build'
assert_contains "$EVENTS" 'cabal build --project-file=cabal-native-opt.project'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the server does not answer after the bootstrap installed zlib'
undeploy >/dev/null 2>&1
pass 'on Debian a missing package is a warning: the bootstrap installs it, and the check after it stops the deploy or lets it go on'

# A deployment that downloads its page from GitHub (--backend-only, WP5.49),
# as on a machine with no npm registry and no Node: the fixture's repository
# is a git checkout whose origin is on GitHub, the fake curl answers for
# GitHub's releases (FAKE_GITHUB), and there is no Node, managed or on PATH
# (the deploy's own; the fakes still use the real one).
github_page_fixture() {
  fixture "$1"
  rm -rf "$HOME/.wiki-toolchain"
  (
    cd "$case_dir/repo"
    git init -q
    git add -A
    git -c user.name=tester -c user.email=tester@example.com commit -q -m 'The checkout'
    git remote add origin "${2:-git@github.com:Owner/blog.git}"
  )
  head1=$(git -C "$case_dir/repo" rev-parse HEAD)
  FAKE_GITHUB=$case_dir/github
  export FAKE_GITHUB
  mkdir -p "$FAKE_GITHUB/releases" "$FAKE_GITHUB/download/main-latest"
  # The page CI builds for the server, its files at the zip's root.
  page=$case_dir/page
  mkdir -p "$page/s"
  printf '<!doctype html><meta name="wiki-backend" content="server"><title>wiki</title>%2000s' '' >"$page/index.html"
  printf '<!doctype html><title>missing</title>' >"$page/404.html"
  head -c 4096 /dev/zero >"$page/app.wasm"
  printf 'console.log(1);\n' >"$page/index.js"
  # And the demo's, a page per route, which says it is the demo's.
  demo_page=$case_dir/demo-page
  mkdir -p "$demo_page/s/blog"
  printf '<!doctype html><meta name="wiki-backend" content="demo"><title>demo</title>%2000s' '' >"$demo_page/index.html"
  printf '<!doctype html><title>demo blog</title>%2000s' '' >"$demo_page/s/blog/index.html"
  printf '<!doctype html><title>missing</title>' >"$demo_page/404.html"
  head -c 4096 /dev/zero >"$demo_page/app.wasm"
  printf 'console.log(2);\n' >"$demo_page/index.js"
  other=1111111111111111111111111111111111111111
  newest=2222222222222222222222222222222222222222
  for commit in "$other" "$newest" "$head1"; do
    page_zip "$FAKE_GITHUB/download/main-latest/app-server-$commit.zip"
    page_zip "$FAKE_GITHUB/download/main-latest/app-demo-$commit.zip" "$demo_page"
  done
}
# A zip of a page's files at its root, as CI makes it: the server's page, or
# the directory given second.
page_zip() {
  python3 -c '
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for d, _, files in os.walk(root):
        for f in files:
            z.write(os.path.join(d, f), os.path.relpath(os.path.join(d, f), root))
' "${2:-$page}" "$1"
}
# A release's JSON as the API gives it: its tag, and its assets with the
# times they were uploaded at, given as name time pairs, their sizes, those
# of the files under download/<tag>/ (0 for an asset with no file), and ids
# made from the name and the time, so that an asset uploaded again, at
# another time, gets another id, as on GitHub.
release() {
  tag=$1
  shift
  {
    printf '{"tag_name":"%s","prerelease":true,"assets":[' "$tag"
    sep=
    while [ $# -gt 0 ]; do
      size=$(wc -c <"$FAKE_GITHUB/download/$tag/$1" 2>/dev/null || printf 0)
      id=$(printf '%s %s' "$1" "$2" | cksum | cut -d' ' -f1)
      printf '%s{"id":%s,"name":"%s","updated_at":"%s","size":%s,"browser_download_url":"https://github.com/Owner/blog/releases/download/%s/%s"}' "$sep" "$id" "$1" "$2" "$size" "$tag" "$1"
      sep=,
      shift 2
    done
    printf ']}\n'
  } >"$FAKE_GITHUB/releases/$tag.json"
}
pstate() { sed -n "s/^$1=//p" "$pre/state/wiki-demo.state"; }

github_page_fixture backend-only
pre=$case_dir/srv/wiki
p=$(free_port 127.0.0.1)
a=$(other_port "$p")
# The command for the company machine, with the ports of the test.
company() { deploy --server --sqlite --prefix "$pre" --bind 0.0.0.0 --no-firewall --port "$p" --admin-port "$a" "$@"; }
release main-latest "app-server-$other.zip" 2026-11-01T10:00:00Z "app-server-$newest.zip" 2026-11-02T10:00:00Z
out=$case_dir/no-page
if company --backend-only >"$out" 2>&1; then fail 'a checkout with no page on GitHub was deployed'; fi
assert_contains "$out" "no page was built for $head1 on GitHub; push it, or name main, a tag or another hash"
assert_lacks "$EVENTS" 'bootstrap'
assert_lacks "$EVENTS" 'cabal'
assert_lacks "$EVENTS" 'npm'
: >"$EVENTS"
out=$case_dir/static
if deploy --static --backend-only --prefix "$pre" --port "$p" >"$out" 2>&1; then fail '--static --backend-only with no demo page was taken'; fi
assert_contains "$out" "no demo page was built for $head1 on GitHub; push it, or name main, a tag or another hash"
assert_lacks "$EVENTS" 'curl https://github.com/'
assert_lacks "$EVENTS" 'bootstrap'
assert_lacks "$EVENTS" 'npm'
pass '--backend-only for a commit with no page on GitHub, of the server or of the demo, is refused before anything is built'

release main-latest "app-server-$other.zip" 2026-11-01T10:00:00Z "app-server-$newest.zip" 2026-11-02T10:00:00Z "app-server-$head1.zip" 2026-10-31T10:00:00Z
: >"$EVENTS"
out=$case_dir/first
company --backend-only >"$out" 2>&1 || fail 'the deploy with --backend-only failed'
assert_contains "$EVENTS" "curl https://api.github.com/repos/Owner/blog/releases/tags/main-latest"
assert_contains "$EVENTS" "curl https://github.com/Owner/blog/releases/download/main-latest/app-server-$head1.zip"
assert_contains "$EVENTS" "bootstrap native --without-postgres WIKI_TOOLCHAIN_HOME=$pre/toolchain"
assert_lacks "$EVENTS" 'bootstrap build'
assert_lacks "$EVENTS" 'npm'
assert_contains "$EVENTS" 'cabal build --project-file=cabal-native-opt.project --builddir=dist-newstyle/native-opt wiki-server:exe:wiki-server'
assert_contains "$out" 'Building executable wiki-server for wiki-server-0.1.0.0 (the fake cabal)'
{ [ "$(line_of "$EVENTS" 'curl https://github.com/')" -lt "$(line_of "$EVENTS" 'bootstrap native')" ] &&
  [ "$(line_of "$EVENTS" 'bootstrap native')" -lt "$(line_of "$EVENTS" 'cabal build')" ]; } ||
  fail 'the page was not downloaded before the toolchain and the build'
assert_contains "$EVENTS" "wiki-server compress $pre/app"
for file in app/index.html app/404.html app/app.wasm app/app.wasm.gz app/index.html.gz bin/wiki-server; do
  [ -f "$pre/$file" ] || fail "missing $file"
done
[ ! -e "$pre/app/index.js.gz" ] || fail 'a file under 1 KiB was compressed'
[ -z "$(find "$pre/app" -name '*.br')" ] || fail 'brotli copies without Node'
[ ! -e "$pre/toolchain/.wiki-toolchain/node" ] && [ ! -e "$HOME/.wiki-toolchain/node" ] || fail 'a Node was installed'
assert_contains "$out" 'gzip copies by wiki-server compress, since there is no Node here for brotli ones: Wrote 2 gzip copies'
assert_contains "$HOME/$unit" "--listen 0.0.0.0:$p --admin-listen 127.0.0.1:$a --sqlite"
assert_contains "$out" "answers on http://127.0.0.1:$p/api/v1/info"
assert_contains "$out" "its admin listener answers on http://127.0.0.1:$a/admin/"
assert_lacks "$out" 'warning: the page is of'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the server does not answer'
[ "$(http_get "http://127.0.0.1:$p/")" = '200 text/html' ] || fail 'the downloaded page is not served'
{ [ "$(pstate backend_only)" = head ] && [ "$(pstate backend_only_commit)" = "$head1" ] && [ "$(pstate https)" = no ]; } ||
  fail 'the state does not record the page from GitHub'
cmp "$pre/toolchain/.wiki-toolchain/pages/app-server-$head1.zip" "$FAKE_GITHUB/download/main-latest/app-server-$head1.zip" ||
  fail 'the downloaded page was not kept in the cache under the toolchain directory'
[ -z "$(find "$pre/toolchain/.wiki-toolchain/pages" -name '.*')" ] || fail 'the cache keeps a temporary file'
assert_contains "$pre/toolchain/.wiki-toolchain/pages/app-server-$head1.zip.meta" "id=$(printf '%s %s' "app-server-$head1.zip" 2026-10-31T10:00:00Z | cksum | cut -d' ' -f1) updated_at=2026-10-31T10:00:00Z size="
pass '--backend-only downloads the checkout'"'"'s page from its GitHub release, builds wiki-server alone after bootstrap native, without npm or Node, and serves it with gzip copies'

# A wiki in SQLite needs no libpq, in the bootstrap's check either (Codex's
# first round on #141). On a machine with neither pg_config nor dpkg-query,
# --sqlite --backend-only passes the deploy's check and the bootstrap's,
# both told --without-postgres; --postgres on the same machine stops at the
# deploy's check, naming libpq, before the bootstrap or a build.
no_libpq=$case_dir/no-libpq
mkdir "$no_libpq"
for cmd in "$NO_DPKG"/*; do
  name=${cmd##*/}
  [ "$name" != pg_config ] || continue
  ln -s "$(readlink "$cmd")" "$no_libpq/$name"
done
mv "$case_dir/bin/pg_config" "$case_dir/pg_config.aside"
: >"$EVENTS"
out=$case_dir/no-libpq-sqlite
(
  PATH=$case_dir/bin:$no_libpq WIKI_PG_CONFIG_DIRS=$case_dir/nowhere
  export PATH WIKI_PG_CONFIG_DIRS
  company --backend-only
) >"$out" 2>&1 || fail "--sqlite --backend-only without libpq failed: $(cat "$out")"
assert_contains "$EVENTS" "bootstrap native --without-postgres WIKI_TOOLCHAIN_HOME=$pre/toolchain"
assert_contains "$out" 'skipped  libpq       not needed (built without PostgreSQL)'
assert_lacks "$out" 'missing'
assert_contains "$EVENTS" 'cabal build --project-file=cabal-native-opt.project --builddir=dist-newstyle/native-opt wiki-server:exe:wiki-server --constraint=wiki-server -postgres'
: >"$EVENTS"
out=$case_dir/no-libpq-postgres
status=0
(
  PATH=$case_dir/bin:$no_libpq WIKI_PG_CONFIG_DIRS=$case_dir/nowhere
  export PATH WIKI_PG_CONFIG_DIRS
  deploy --server --postgres --prefix "$pre" --bind 0.0.0.0 --no-firewall --port "$p" --admin-port "$a" --backend-only
) >"$out" 2>&1 || status=$?
[ "$status" != 0 ] || fail '--postgres without libpq was deployed'
assert_contains "$out" 'missing  libpq       no pg_config on PATH'
assert_contains "$out" 'the native build of wiki-server needs what is missing above; nothing was changed'
assert_lacks "$EVENTS" 'bootstrap'
assert_lacks "$EVENTS" 'cabal'
mv "$case_dir/pg_config.aside" "$case_dir/bin/pg_config"
pass 'a wiki in SQLite deploys with --backend-only on a machine without libpq, through the bootstrap'"'"'s check too; one in PostgreSQL stops there, naming libpq'

: >"$EVENTS"
assert_lacks "$HOME/$unit" 'LD_LIBRARY_PATH'
out=$case_dir/no-build
LD_LIBRARY_PATH=/opt/libs/lib deploy --prefix "$pre" --no-build >"$out" 2>&1 || fail 'the redeploy with --no-build failed'
assert_contains "$HOME/$unit" 'Environment="LD_LIBRARY_PATH=/opt/libs/lib"'
assert_contains "$out" 'the unit runs wiki-server with LD_LIBRARY_PATH=/opt/libs/lib'
assert_lacks "$EVENTS" 'curl https://'
assert_lacks "$EVENTS" 'bootstrap'
assert_lacks "$EVENTS" 'npm'
{ [ "$(pstate backend_only)" = head ] && [ "$(pstate backend_only_commit)" = "$head1" ]; } || fail '--no-build forgot the page from GitHub'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the server does not answer after --no-build'
out=$case_dir/status
deploy --status --prefix "$pre" >"$out" 2>&1
assert_contains "$out" "its page is downloaded from GitHub (--backend-only=head, the page of $head1)"
pass 'a redeploy with --no-build keeps the page and the choice, and gives the unit the LD_LIBRARY_PATH of its shell; --status says where the page comes from'

# A second deploy of the same commit takes its page from the cache and
# downloads nothing; --refresh-page downloads it again, for that run only.
cache=$pre/toolchain/.wiki-toolchain/pages
: >"$EVENTS"
out=$case_dir/cached
deploy --prefix "$pre" >"$out" 2>&1 || fail 'the redeploy from the cache failed'
assert_contains "$EVENTS" 'curl https://api.github.com/repos/Owner/blog/releases/tags/main-latest'
assert_lacks "$EVENTS" 'curl https://github.com/'
assert_contains "$out" "the page of $head1 from the cache: $cache/app-server-$head1.zip"
assert_lacks "$out" 'downloading the page'
[ "$(http_get "http://127.0.0.1:$p/")" = '200 text/html' ] || fail 'the page from the cache is not served'
: >"$EVENTS"
out=$case_dir/refresh
deploy --prefix "$pre" --refresh-page >"$out" 2>&1 || fail '--refresh-page failed'
assert_contains "$EVENTS" "curl https://github.com/Owner/blog/releases/download/main-latest/app-server-$head1.zip"
assert_lacks "$out" 'from the cache'
assert_lacks "$pre/state/wiki-demo.state" 'refresh'
pass 'a second deploy of the same commit takes the page from the cache and downloads nothing; --refresh-page downloads it again'

# A commit that changes Markdown alone has no page of its own (CI ignores
# it); the page of the commit before it is the same.
printf 'notes\n' >"$case_dir/repo/NOTES.md"
git -C "$case_dir/repo" add NOTES.md
git -C "$case_dir/repo" -c user.name=tester -c user.email=tester@example.com commit -q -m 'Notes'
: >"$EVENTS"
out=$case_dir/markdown
deploy --prefix "$pre" >"$out" 2>&1 || fail 'the deploy of a commit changing Markdown alone failed'
assert_lacks "$HOME/$unit" 'LD_LIBRARY_PATH'
assert_contains "$out" "changes Markdown files alone since $head1, which has a page on GitHub: taking that one"
assert_contains "$out" "the page of $head1 from the cache"
assert_lacks "$EVENTS" 'curl https://github.com/'
assert_lacks "$out" 'warning: the page is of'
[ "$(pstate backend_only_commit)" = "$head1" ] || fail 'the page of the commit before was not recorded'
pass 'a checkout whose commit changes Markdown alone takes the page of the commit before it'

# The built-in templates are Markdown compiled into the application, so a
# commit that changes one alone changes the page: CI builds a page for it,
# and the page of the commit before is of another version.
mkdir -p "$case_dir/repo/wiki-core/templates"
printf '# Meeting notes\n' >"$case_dir/repo/wiki-core/templates/meeting-notes.md"
git -C "$case_dir/repo" add wiki-core/templates/meeting-notes.md
git -C "$case_dir/repo" -c user.name=tester -c user.email=tester@example.com commit -q -m 'Template'
head3=$(git -C "$case_dir/repo" rev-parse HEAD)
: >"$EVENTS"
out=$case_dir/template
if deploy --prefix "$pre" >"$out" 2>&1; then fail 'a commit changing a template alone took the page of the commit before'; fi
assert_contains "$out" "no page was built for $head3 on GitHub; push it, or name main, a tag or another hash"
assert_lacks "$out" 'changes Markdown files alone'
assert_lacks "$EVENTS" 'curl https://github.com/'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'a commit with no page took the server down'
: >"$EVENTS"
out=$case_dir/template-other-page
deploy --prefix "$pre" --backend-only="$head1" >"$out" 2>&1 || fail "--backend-only=$head1 failed"
assert_contains "$out" "the page of $head1 from the cache"
assert_contains "$out" "warning: the page is of $head1, and wiki-server is built from this checkout"
pass 'a commit that changes a built-in template alone has no page of the commit before, and that page is of another version'

: >"$EVENTS"
out=$case_dir/main
deploy --prefix "$pre" --backend-only=main >"$out" 2>&1 || fail '--backend-only=main failed'
assert_contains "$EVENTS" "curl https://github.com/Owner/blog/releases/download/main-latest/app-server-$newest.zip"
assert_contains "$out" "warning: the page is of $newest, and wiki-server is built from this checkout"
{ [ "$(pstate backend_only)" = main ] && [ "$(pstate backend_only_commit)" = "$newest" ]; } || fail 'the state does not record main'
: >"$EVENTS"
deploy --prefix "$pre" >"$out" 2>&1 || fail 'the redeploy of main failed'
assert_contains "$out" "the page of $newest from the cache"
[ "$(pstate backend_only)" = main ] || fail 'a redeploy without the flag forgot main'
pass '--backend-only=main takes the newest page of main, warns that it is of another commit, and is remembered'

: >"$EVENTS"
out=$case_dir/prefix
deploy --prefix "$pre" --backend-only=11111111 >"$out" 2>&1 || fail 'a hash prefix failed'
assert_contains "$EVENTS" "app-server-$other.zip"
[ "$(pstate backend_only_commit)" = "$other" ] || fail 'the hash prefix did not take its page'
out=$case_dir/unknown
if deploy --prefix "$pre" --backend-only=abcdef12 >"$out" 2>&1; then fail 'a hash with no page was deployed'; fi
assert_contains "$out" 'no page was built for abcdef12 on GitHub; push it, or name main, a tag or another hash'
mkdir -p "$FAKE_GITHUB/download/v9.9"
page_zip "$FAKE_GITHUB/download/v9.9/app-server-v9.9.zip"
release v9.9 app-server-v9.9.zip 2026-10-01T10:00:00Z
: >"$EVENTS"
out=$case_dir/tag
deploy --prefix "$pre" --backend-only=v9.9 >"$out" 2>&1 || fail 'a tag failed'
assert_contains "$EVENTS" 'curl https://github.com/Owner/blog/releases/download/v9.9/app-server-v9.9.zip'
assert_contains "$out" 'cannot tell which commit the page of v9.9 was built from'
{ [ "$(pstate backend_only)" = v9.9 ] && [ -z "$(pstate backend_only_commit)" ]; } || fail 'the state does not record the tag'
# A tag's asset can be replaced (CI uploads it again with --clobber): the
# cached one is taken while the release lists the asset with the id and time
# in its .meta file, and downloaded again when either changed, even at the
# same size, or when the .meta file is missing.
: >"$EVENTS"
out=$case_dir/tag-cached
deploy --prefix "$pre" >"$out" 2>&1 || fail 'the redeploy of a tag failed'
assert_lacks "$EVENTS" 'curl https://github.com/'
assert_contains "$out" "the page of v9.9 from the cache: $cache/app-server-v9.9.zip"
cp -r "$page" "$case_dir/page2"
printf 'version one of v9.9\n' >"$case_dir/page2/extra.txt"
page_zip "$FAKE_GITHUB/download/v9.9/app-server-v9.9.zip" "$case_dir/page2"
release v9.9 app-server-v9.9.zip 2026-10-02T10:00:00Z
: >"$EVENTS"
out=$case_dir/tag-replaced
deploy --prefix "$pre" >"$out" 2>&1 || fail 'the redeploy of a replaced tag failed'
assert_contains "$EVENTS" 'curl https://github.com/Owner/blog/releases/download/v9.9/app-server-v9.9.zip'
assert_lacks "$out" 'from the cache'
cmp "$cache/app-server-v9.9.zip" "$FAKE_GITHUB/download/v9.9/app-server-v9.9.zip" || fail 'the cache kept the replaced asset'
[ -f "$pre/app/extra.txt" ] || fail "the replaced tag's page was not deployed"
assert_contains "$cache/app-server-v9.9.zip.meta" 'updated_at=2026-10-02T10:00:00Z'
# Uploaded again, with another file of the same size: the same length,
# another id and time.
old_size=$(wc -c <"$FAKE_GITHUB/download/v9.9/app-server-v9.9.zip")
cp -r "$page" "$case_dir/page3"
printf 'version two of v9.9\n' >"$case_dir/page3/extra.txt"
page_zip "$FAKE_GITHUB/download/v9.9/app-server-v9.9.zip" "$case_dir/page3"
[ "$(wc -c <"$FAKE_GITHUB/download/v9.9/app-server-v9.9.zip")" = "$old_size" ] || fail 'the fixture: the second zip is not of the first one'"'"'s size'
release v9.9 app-server-v9.9.zip 2026-10-03T10:00:00Z
: >"$EVENTS"
out=$case_dir/tag-same-size
deploy --prefix "$pre" >"$out" 2>&1 || fail 'the redeploy of a tag replaced at the same size failed'
assert_contains "$EVENTS" 'curl https://github.com/Owner/blog/releases/download/v9.9/app-server-v9.9.zip'
assert_lacks "$out" 'from the cache'
assert_contains "$pre/app/extra.txt" 'version two of v9.9'
assert_contains "$cache/app-server-v9.9.zip.meta" 'updated_at=2026-10-03T10:00:00Z'
: >"$EVENTS"
out=$case_dir/tag-unchanged
deploy --prefix "$pre" >"$out" 2>&1 || fail 'the redeploy of an unchanged tag failed'
assert_lacks "$EVENTS" 'curl https://github.com/'
assert_contains "$out" "the page of v9.9 from the cache: $cache/app-server-v9.9.zip"
rm "$cache/app-server-v9.9.zip.meta"
: >"$EVENTS"
out=$case_dir/tag-no-meta
deploy --prefix "$pre" >"$out" 2>&1 || fail 'the redeploy of a tag without its .meta file failed'
assert_contains "$EVENTS" 'curl https://github.com/Owner/blog/releases/download/v9.9/app-server-v9.9.zip'
[ -f "$cache/app-server-v9.9.zip.meta" ] || fail 'the download did not write the .meta file again'
out=$case_dir/no-tag
if deploy --prefix "$pre" --backend-only=v0.0-none >"$out" 2>&1; then fail 'a tag with no release was deployed'; fi
assert_contains "$out" 'GitHub has no release v0.0-none with a page'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'a refused REF took the server down'
pass '--backend-only takes a hash prefix, a tag'"'"'s release, and refuses a hash or a tag with no page; a tag'"'"'s cached page is taken while GitHub'"'"'s asset is the same by id and time, and downloaded again when it was replaced, even at the same size'

# The cache keeps the five newest zips: after a download, older ones go. A
# zip that goes takes its .meta file with it.
rm -f "$cache"/*.zip "$cache"/*.meta
for i in 1 2 3 4 5 6; do
  : >"$cache/app-server-old$i.zip"
  touch -d "$i hours ago" "$cache/app-server-old$i.zip"
done
printf 'id=1 updated_at=- size=0\n' >"$cache/app-server-old6.zip.meta"
: >"$EVENTS"
out=$case_dir/prune
deploy --prefix "$pre" --refresh-page >"$out" 2>&1 || fail 'the deploy that prunes the cache failed'
[ "$(find "$cache" -name '*.zip' | wc -l)" -eq 5 ] || fail "the cache holds $(find "$cache" -name '*.zip' | wc -l) zips, not five"
for kept in app-server-v9.9.zip app-server-old1.zip app-server-old2.zip app-server-old3.zip app-server-old4.zip; do
  [ -f "$cache/$kept" ] || fail "the prune deleted $kept"
done
[ ! -e "$cache/app-server-old6.zip.meta" ] || fail 'the prune left the .meta file of a zip it deleted'
pass 'after a download the cache keeps its five newest zips, and deletes the .meta files of the others'

# A machine without libsodium that is not Debian (no dpkg-query on PATH),
# so nothing would install it: the check refuses.
: >"$EVENTS"
out=$case_dir/no-libsodium
if FAKE_NO_LIBSODIUM=1 PATH=$case_dir/bin:$NO_DPKG deploy --prefix "$pre" >"$out" 2>&1; then fail 'a machine without libsodium deployed'; fi
assert_contains "$out" 'missing  libsodium   cc cannot compile and link a program with sodium.h and -lsodium (Debian: libsodium-dev; RHEL: libsodium-devel)'
assert_contains "$out" 'RHEL has libsodium in EPEL only'
assert_contains "$out" 'LIBRARY_PATH=<dir>/lib C_INCLUDE_PATH=<dir>/include PKG_CONFIG_PATH=<dir>/lib/pkgconfig'
assert_lacks "$EVENTS" 'curl https://'
assert_lacks "$EVENTS" 'bootstrap'
assert_lacks "$EVENTS" 'cabal'
# One built from source into a directory of its own: PKG_CONFIG_PATH alone
# is not enough, since the build links -lsodium without pkg-config, and the
# check says which directories to give it.
mkdir -p "$case_dir/libsodium/lib/pkgconfig" "$case_dir/libsodium/include"
touch "$case_dir/libsodium/lib/pkgconfig/libsodium.pc" "$case_dir/libsodium/lib/libsodium.a" "$case_dir/libsodium/include/sodium.h"
: >"$EVENTS"
out=$case_dir/pkg-config-libsodium
if FAKE_NO_LIBSODIUM=1 PKG_CONFIG_PATH=$case_dir/libsodium/lib/pkgconfig PATH=$case_dir/bin:$NO_DPKG deploy --prefix "$pre" >"$out" 2>&1; then
  fail 'a libsodium named by PKG_CONFIG_PATH alone was taken'
fi
assert_contains "$out" "pkg-config finds a libsodium in $case_dir/libsodium/lib, but cc does not: the build looks where cc does, so give it LIBRARY_PATH=$case_dir/libsodium/lib C_INCLUDE_PATH=$case_dir/libsodium/include"
assert_lacks "$EVENTS" 'cabal'
: >"$EVENTS"
out=$case_dir/own-libsodium
FAKE_NO_LIBSODIUM=1 LIBRARY_PATH=$case_dir/libsodium/lib C_INCLUDE_PATH=$case_dir/libsodium/include deploy --prefix "$pre" >"$out" 2>&1 ||
  fail 'a libsodium named by LIBRARY_PATH and C_INCLUDE_PATH was not taken'
assert_contains "$out" 'ok       libsodium   sodium.h and -lsodium, through cc'
assert_contains "$EVENTS" "LIBRARY_PATH=$case_dir/libsodium/lib C_INCLUDE_PATH=$case_dir/libsodium/include"
: >"$EVENTS"
out=$case_dir/no-library
if FAKE_CABAL_NO_LIBRARY=1 deploy --prefix "$pre" >"$out" 2>&1; then fail 'a build that lacks a library deployed'; fi
assert_contains "$out" 'the build of wiki-server lacks a C library or pkg-config (see above): sh toolchain/check-native.sh says what is missing'
assert_lacks "$EVENTS" 'systemctl stop'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'a failed build took the server down'
pass 'a machine without libsodium is refused before the build by toolchain/check-native.sh, which names its packages and the directories to give the build; LIBRARY_PATH and C_INCLUDE_PATH reach the build; a build that lacks a library points at the check'

# A build that fails in a dependency's log, as on the RHEL server whose GHC
# could not open cabal's semaphore: the deploy shows the newest log written
# during the build, its path and its last 30 lines, with the semaphore hint,
# and installs nothing. A log from before the build is not the one shown.
mkdir -p "$CABAL_DIR/logs/ghc-9.14.1"
printf 'an earlier build\n' >"$CABAL_DIR/logs/ghc-9.14.1/zlib-0.7.1.0-old.log"
touch -d '1 hour ago' "$CABAL_DIR/logs/ghc-9.14.1/zlib-0.7.1.0-old.log"
: >"$EVENTS"
out=$case_dir/semopen
if FAKE_CABAL_SEMOPEN=1 deploy --prefix "$pre" >"$out" 2>&1; then fail 'a build that failed in a dependency deployed'; fi
assert_contains "$out" 'See the build log above for details.'
assert_contains "$out" "the newest build log, $CABAL_DIR/logs/ghc-9.14.1/splitmix-0.1.3.1-abc123.log, ends with:"
assert_contains "$out" 'Building library line 4'
assert_contains "$out" 'Building library line 32'
assert_contains "$out" 'cabal_semaphore_y: semOpen: does not exist (no such file or directory)'
assert_contains "$out" "GHC could not open cabal's build semaphore (semOpen, see above): deploy again with --no-semaphore, which builds without it"
assert_contains "$out" 'the build of wiki-server failed (see above), so nothing was changed'
assert_lacks "$out" 'zlib-0.7.1.0-old.log'
assert_lacks "$out" 'an earlier build'
assert_lacks "$out" 'lacks a C library'
assert_lacks "$EVENTS" 'systemctl stop'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'a failed build took the server down'
pass "a build that fails in a dependency's log shows that log's path and last lines, and a semOpen in it points at the semaphore; nothing is installed"

# The build semaphore. A probe that finds it unusable, or that cannot run,
# builds without it; --semaphore and --no-semaphore decide without the
# probe, either way.
: >"$EVENTS"
out=$case_dir/semaphore-unusable
FAKE_SEMAPHORE=1 deploy --prefix "$pre" >"$out" 2>&1 || fail 'a deploy whose probe found the semaphore unusable failed'
assert_contains "$out" 'build semaphore: not usable (wiki_semaphore_probe_1: semOpen: does not exist (No such file or directory)), building without it'
assert_contains "$EVENTS" 'check-semaphore'
assert_contains "$EVENTS" 'wiki-server -postgres --no-semaphore'
assert_lacks "$EVENTS" ' --semaphore'
: >"$EVENTS"
out=$case_dir/semaphore-no-probe
FAKE_SEMAPHORE=2 deploy --prefix "$pre" >"$out" 2>&1 || fail 'a deploy whose probe could not run failed'
assert_contains "$out" 'build semaphore: not usable (the probe could not run: no ghc (ghc) to run the probe), building without it'
assert_contains "$EVENTS" 'wiki-server -postgres --no-semaphore'
assert_lacks "$EVENTS" ' --semaphore'
: >"$EVENTS"
out=$case_dir/semaphore-forced
FAKE_SEMAPHORE=1 deploy --prefix "$pre" --semaphore >"$out" 2>&1 || fail '--semaphore failed'
assert_contains "$out" 'build semaphore: on, as --semaphore asks (not probed)'
assert_lacks "$EVENTS" 'check-semaphore'
assert_contains "$EVENTS" 'wiki-server -postgres --semaphore'
: >"$EVENTS"
out=$case_dir/semaphore-refused
deploy --prefix "$pre" --no-semaphore >"$out" 2>&1 || fail '--no-semaphore failed'
assert_contains "$out" 'build semaphore: off, as --no-semaphore asks'
assert_lacks "$EVENTS" 'check-semaphore'
assert_contains "$EVENTS" 'wiki-server -postgres --no-semaphore'
assert_lacks "$EVENTS" ' --semaphore'
# Not remembered: the next run probes again.
: >"$EVENTS"
deploy --prefix "$pre" >"$case_dir/semaphore-again" 2>&1 || fail 'the deploy after --no-semaphore failed'
assert_contains "$EVENTS" 'check-semaphore'
assert_contains "$EVENTS" 'wiki-server -postgres --semaphore'
# --no-build builds nothing, so it probes nothing.
: >"$EVENTS"
deploy --prefix "$pre" --no-build >"$case_dir/semaphore-no-build" 2>&1 || fail 'the deploy with --no-build failed'
assert_lacks "$EVENTS" 'check-semaphore'
pass 'the build uses the semaphore when the probe finds it usable, not when the probe fails or cannot run, and --semaphore and --no-semaphore decide without the probe, for one run'

out=$case_dir/stop
deploy --prefix "$pre" --stop >"$out" 2>&1 || fail '--stop failed'
[ "$(pstate backend_only)" = v9.9 ] || fail '--stop forgot the page from GitHub'
: >"$EVENTS"
out=$case_dir/back
deploy --prefix "$pre" --no-backend-only >"$out" 2>&1 || fail '--no-backend-only failed'
assert_contains "$EVENTS" "bootstrap build --without-postgres WIKI_TOOLCHAIN_HOME=$pre/toolchain"
assert_contains "$EVENTS" 'npm run build-wasm-opt HALOGEN_BASE_PATH=/ WIKI_BACKEND=server'
[ -z "$(pstate backend_only)" ] || fail '--no-backend-only was not recorded'
[ -f "$pre/app/app.wasm.br" ] || fail 'the page built here has no brotli copies'
undeploy --prefix "$pre" >/dev/null 2>&1
pass '--stop keeps the choice, and --no-backend-only builds the page here again'

# The demo from GitHub (--static --backend-only): the demo's page CI built
# is downloaded and served by server.mjs under Node, the one thing the
# bootstrap installs (its node mode). Nothing is built: no cabal, no npm,
# no wasm build. github_page_fixture leaves no managed Node, and the
# fixture's PATH has none, so the bootstrap must install it.
github_page_fixture backend-static
pre=$case_dir/srv/wiki
p=$(free_port 127.0.0.1)
a=$(other_port "$p")
release main-latest "app-server-$other.zip" 2026-11-01T10:00:00Z "app-demo-$other.zip" 2026-11-01T10:00:00Z \
  "app-server-$newest.zip" 2026-11-02T10:00:00Z "app-demo-$newest.zip" 2026-11-02T10:00:00Z \
  "app-server-$head1.zip" 2026-10-31T10:00:00Z "app-demo-$head1.zip" 2026-10-31T10:00:00Z
out=$case_dir/first
deploy --static --http --bind 127.0.0.1 --port "$p" --prefix "$pre" --backend-only >"$out" 2>&1 || fail 'the deploy with --static --backend-only failed'
assert_contains "$EVENTS" "curl https://api.github.com/repos/Owner/blog/releases/tags/main-latest"
assert_contains "$EVENTS" "curl https://github.com/Owner/blog/releases/download/main-latest/app-demo-$head1.zip"
assert_contains "$EVENTS" "bootstrap node WIKI_TOOLCHAIN_HOME=$pre/toolchain"
assert_lacks "$EVENTS" 'app-server-'
assert_lacks "$EVENTS" 'bootstrap build'
assert_lacks "$EVENTS" 'bootstrap native'
assert_lacks "$EVENTS" 'cabal'
assert_lacks "$EVENTS" 'npm'
assert_lacks "$EVENTS" 'wiki-server'
assert_contains "$HOME/$unit" "ExecStart=\"$pre/toolchain/.wiki-toolchain/node/bin/node\" \"$pre/server.mjs\" --root \"$pre/app\" --port $p --bind 127.0.0.1"
assert_contains "$pre/app/index.html" '<title>demo</title>'
for file in app/s/blog/index.html app/404.html app/app.wasm.br app/index.html.br app/s/blog/index.html.br server.mjs; do
  [ -f "$pre/$file" ] || fail "missing $file"
done
[ -z "$(find "$pre/app" -name '*.gz')" ] || fail 'gzip copies with Node at hand'
[ ! -e "$pre/bin" ] || fail 'a wiki-server was installed for the demo'
assert_lacks "$out" 'warning: the'
[ "$(http_get "http://127.0.0.1:$p/")" = '200 text/html; charset=utf-8' ] || fail 'the demo is not served'
[ "$(http_get "http://127.0.0.1:$p/s/blog/")" = '200 text/html; charset=utf-8' ] || fail "the demo's page of a route is not served"
{ [ "$(pstate mode)" = static ] && [ "$(pstate backend_only)" = head ] && [ "$(pstate backend_only_commit)" = "$head1" ]; } ||
  fail 'the state does not record the demo from GitHub'
pass '--static --backend-only downloads the demo'"'"'s page, installs Node alone, builds nothing, and serves it with server.mjs and brotli copies'

: >"$EVENTS"
out=$case_dir/no-build
deploy --prefix "$pre" --no-build >"$out" 2>&1 || fail 'the redeploy of the demo with --no-build failed'
assert_lacks "$EVENTS" 'curl https://'
assert_lacks "$EVENTS" 'bootstrap'
assert_lacks "$EVENTS" 'cabal'
assert_lacks "$EVENTS" 'npm'
assert_contains "$pre/app/index.html" '<title>demo</title>'
[ "$(http_get "http://127.0.0.1:$p/")" = '200 text/html; charset=utf-8' ] || fail 'the demo is not served after --no-build'
{ [ "$(pstate backend_only)" = head ] && [ "$(pstate backend_only_commit)" = "$head1" ]; } || fail '--no-build forgot the demo from GitHub'
out=$case_dir/status
deploy --status --prefix "$pre" >"$out" 2>&1
assert_contains "$out" "its page, the demo's, is downloaded from GitHub (--backend-only=head, the page of $head1), and nothing is built here"
out=$case_dir/stop
deploy --prefix "$pre" --stop >"$out" 2>&1 || fail '--stop of the demo failed'
[ "$(pstate backend_only)" = head ] || fail '--stop forgot the demo from GitHub'
: >"$EVENTS"
out=$case_dir/main
deploy --prefix "$pre" --backend-only=main >"$out" 2>&1 || fail '--static --backend-only=main failed'
assert_contains "$EVENTS" "curl https://github.com/Owner/blog/releases/download/main-latest/app-demo-$newest.zip"
assert_contains "$out" "warning: the demo page is of $newest, and this checkout is $head1"
{ [ "$(pstate backend_only)" = main ] && [ "$(pstate backend_only_commit)" = "$newest" ]; } || fail 'the state does not record main for the demo'
[ "$(http_get "http://127.0.0.1:$p/")" = '200 text/html; charset=utf-8' ] || fail 'the demo of main is not served'
pass 'the demo from GitHub keeps its choice through --no-build and --stop, --status says so, and a demo page of another commit is warned of'

# From the demo to the server and back, the choice of the page from GitHub
# kept: each takes its own kind of page.
: >"$EVENTS"
out=$case_dir/to-server
deploy --server --sqlite --prefix "$pre" --admin-port "$a" --backend-only >"$out" 2>&1 || fail 'the move from the demo to the server failed'
assert_contains "$EVENTS" "curl https://github.com/Owner/blog/releases/download/main-latest/app-server-$head1.zip"
assert_lacks "$EVENTS" 'app-demo-'
assert_contains "$EVENTS" "bootstrap native --without-postgres WIKI_TOOLCHAIN_HOME=$pre/toolchain"
assert_contains "$EVENTS" 'cabal build --project-file=cabal-native-opt.project'
assert_lacks "$EVENTS" 'npm'
assert_contains "$HOME/$unit" "\"$pre/bin/wiki-server\" serve"
assert_contains "$pre/app/index.html" '<title>wiki</title>'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the server does not answer after the move from the demo'
{ [ "$(pstate mode)" = server ] && [ "$(pstate backend_only)" = head ]; } || fail 'the state does not record the server from GitHub'
: >"$EVENTS"
out=$case_dir/to-demo
deploy --static --prefix "$pre" >"$out" 2>&1 || fail 'the move from the server back to the demo failed'
assert_contains "$out" "the page of $head1 from the cache: $pre/toolchain/.wiki-toolchain/pages/app-demo-$head1.zip"
assert_lacks "$EVENTS" 'curl https://github.com/'
assert_lacks "$EVENTS" 'app-server-'
assert_contains "$EVENTS" "bootstrap node WIKI_TOOLCHAIN_HOME=$pre/toolchain"
assert_lacks "$EVENTS" 'cabal'
assert_lacks "$EVENTS" 'npm'
assert_contains "$out" "keeping the server's data in $pre/data"
assert_contains "$HOME/$unit" "\"$pre/server.mjs\" --root \"$pre/app\""
assert_contains "$pre/app/index.html" '<title>demo</title>'
[ "$(http_get "http://127.0.0.1:$p/")" = '200 text/html; charset=utf-8' ] || fail 'the demo is not served after the move back'
{ [ "$(pstate mode)" = static ] && [ "$(pstate backend_only)" = head ]; } || fail 'the state does not record the demo from GitHub again'
pass 'a move from the demo from GitHub to the server and back downloads the page of each, building wiki-server only for the server'

# --no-build installs the page in place, which is of the last mode built or
# downloaded: a page of the other mode is refused before the service is
# touched, by the kind its <meta name="wiki-backend"> says.
: >"$EVENTS"
out=$case_dir/demo-page-for-server
if deploy --server --sqlite --prefix "$pre" --admin-port "$a" --no-build >"$out" 2>&1; then fail '--server --no-build installed the demo page'; fi
assert_contains "$out" "the page in $case_dir/repo/dist-newstyle/wasm-opt/public/app is the demo's, and this deploy is of the server (--server): run without --no-build, which builds or downloads the server's page"
assert_lacks "$EVENTS" 'systemctl stop'
assert_lacks "$EVENTS" 'systemctl restart'
[ "$(pstate mode)" = static ] || fail 'a refused --no-build changed the state'
[ "$(http_get "http://127.0.0.1:$p/")" = '200 text/html; charset=utf-8' ] || fail 'a refused --no-build took the demo down'
deploy --server --sqlite --prefix "$pre" --admin-port "$a" >"$out" 2>&1 || fail 'the move to the server failed'
: >"$EVENTS"
out=$case_dir/server-page-for-demo
if deploy --static --prefix "$pre" --no-build >"$out" 2>&1; then fail '--static --no-build installed the server page'; fi
assert_contains "$out" "the page in $case_dir/repo/dist-newstyle/wasm-opt/public/app is the server's, and this deploy is of the demo (--static): run without --no-build, which builds or downloads the demo's page"
assert_lacks "$EVENTS" 'systemctl stop'
assert_lacks "$EVENTS" 'systemctl restart'
[ "$(pstate mode)" = server ] || fail 'a refused --no-build changed the state'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'a refused --no-build took the server down'
: >"$EVENTS"
out=$case_dir/server-no-build
deploy --prefix "$pre" --no-build >"$out" 2>&1 || fail 'a --no-build of the server with its own page failed'
assert_contains "$EVENTS" 'systemctl restart wiki-demo.service'
assert_lacks "$EVENTS" 'curl https://github.com/'
[ "$(http_get "http://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the server does not answer after its --no-build'
deploy --static --prefix "$pre" >"$out" 2>&1 || fail 'the move back to the demo failed'
pass '--no-build refuses a page of the other mode before the service is touched, and takes one of its own'

: >"$EVENTS"
out=$case_dir/back
deploy --prefix "$pre" --no-backend-only >"$out" 2>&1 || fail '--no-backend-only for the demo failed'
assert_contains "$EVENTS" "bootstrap build WIKI_TOOLCHAIN_HOME=$pre/toolchain"
assert_contains "$EVENTS" 'npm run build-wasm-opt HALOGEN_BASE_PATH=/ WIKI_BACKEND=demo'
assert_lacks "$EVENTS" 'curl https://github.com/'
[ -z "$(pstate backend_only)" ] || fail '--no-backend-only was not recorded for the demo'
[ "$(http_get "http://127.0.0.1:$p/")" = '200 text/html; charset=utf-8' ] || fail 'the demo built here is not served'
undeploy --prefix "$pre" >/dev/null 2>&1
pass '--no-backend-only builds the demo here again'

# Over HTTPS through tailscale serve, the status of Tailscale and the
# administration's settings are read with python3 rather than Node.
github_page_fixture backend-https https://github.com/Owner/blog
release main-latest "app-server-$head1.zip" 2026-11-01T10:00:00Z
p=$(free_port 127.0.0.1)
a=$(other_port "$p")
out=$case_dir/first
deploy --server --sqlite --backend-only --port "$p" --admin-port "$a" >"$out" 2>&1 || fail 'the deploy with --backend-only over HTTPS failed'
assert_contains "$EVENTS" "tailscale serve --bg http://127.0.0.1:$p"
assert_contains "$out" "it answers on ${https_url}api/v1/info"
assert_contains "$out" "The wiki has no public address yet: set it to $https_url"
assert_contains "$HOME/$unit" '--secure-cookies'
[ "$(state https_host)" = box.tail1234.ts.net ] || fail 'HTTPS was not recorded'
[ ! -e "$HOME/.wiki-toolchain/node" ] || fail 'a Node was installed'
[ -f "$HOME/.cache/wiki-demo/pages/app-server-$head1.zip" ] || fail 'without a toolchain directory of its own, the page is not cached in ~/.cache/wiki-demo/pages'
undeploy >/dev/null 2>&1
pass '--backend-only serves HTTPS through tailscale serve, reading Tailscale and the settings without Node; its page is cached in ~/.cache'

# HTTPS with a certificate of one's own, and behind a reverse proxy
# (WP5.50). The certificates are made with openssl, as a company's
# authority would issue them: an authority, and a certificate for
# wiki.test it signed; another authority, which did not sign it. Without
# openssl these cases are skipped, and said to be.
# The status and media type of a GET over HTTPS, accepting any
# certificate, from the real listener.
https_get() {
  "$NODE_REAL" -e '
    require("node:https").get(process.argv[1], { rejectUnauthorized: false }, (r) => console.log(r.statusCode, r.headers["content-type"]))
      .on("error", () => console.log("unreachable"));
  ' "$1"
}
if command -v openssl >/dev/null 2>&1; then
  certs=$TMP/certs
  mkdir -p "$certs"
  (
    cd "$certs"
    openssl req -x509 -newkey rsa:2048 -nodes -subj '/CN=Test Authority' -days 2 -keyout ca.key -out ca.crt
    openssl req -x509 -newkey rsa:2048 -nodes -subj '/CN=Other Authority' -days 2 -keyout other-ca.key -out other-ca.crt
    openssl req -newkey rsa:2048 -nodes -subj /CN=wiki.test -keyout wiki.key -out wiki.csr
    printf 'subjectAltName=DNS:wiki.test\n' >wiki.ext
    openssl x509 -req -in wiki.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile wiki.ext -out wiki.crt
    cat wiki.crt ca.crt wiki.key >wiki.pem
  ) >"$TMP/certs.log" 2>&1 || { cat "$TMP/certs.log" >&2; fail 'openssl could not make the test certificates'; }

  # The server's own certificate, on 0.0.0.0: no --http implied, no
  # tailscale serve, the port opened in ufw, the probe over HTTPS without
  # checking the certificate, and the files remembered by absolute path.
  fixture tls
  p=$(free_port 127.0.0.1)
  a=$(other_port "$p")
  data=$HOME/wiki-demo/data
  out=$case_dir/first
  (cd "$certs" && deploy --server --sqlite --tls-cert wiki.crt --tls-key wiki.key --bind 0.0.0.0 --port "$p" --admin-port "$a") >"$out" 2>&1 ||
    fail 'the deploy with a certificate of its own failed'
  assert_contains "$HOME/$unit" "--listen 0.0.0.0:$p --admin-listen 127.0.0.1:$a --tls-cert \"$certs/wiki.crt\" --tls-key \"$certs/wiki.key\" --sqlite \"$data/wiki.sqlite\""
  assert_lacks "$HOME/$unit" 'secure-cookies'
  assert_lacks "$out" 'implies --http'
  assert_lacks "$EVENTS" 'tailscale serve'
  assert_contains "$EVENTS" "curl-tls https://127.0.0.1:$p/api/v1/info cacert= connect= insecure=1"
  assert_contains "$out" "answers on https://127.0.0.1:$p/api/v1/info"
  assert_contains "$out" "its admin listener answers on http://127.0.0.1:$a/admin/"
  assert_contains "$EVENTS" "ufw allow in on tailscale0 to any port $p proto tcp comment wiki-demo"
  assert_contains "$out" "  https://wiki.test:$p/   (the name the certificate is for)"
  assert_contains "$out" 'a renewed certificate takes a restart, systemctl --user restart wiki-demo.service'
  assert_contains "$out" 'The wiki has no public address yet: set it to the https:// address people use'
  { [ "$(state way)" = cert ] && [ "$(state tls_cert)" = "$certs/wiki.crt" ] && [ "$(state tls_key)" = "$certs/wiki.key" ] &&
    [ "$(state https)" = no ] && [ "$(state rule_port)" = "$p" ]; } || fail 'state does not record the certificate'
  [ "$(https_get "https://127.0.0.1:$p/api/v1/info")" = '200 application/json' ] || fail 'the server does not answer over HTTPS'
  out=$case_dir/status
  deploy --status >"$out" 2>&1
  assert_contains "$out" "HTTPS by wiki-server itself, with its own certificate (--tls-cert $certs/wiki.crt --tls-key $certs/wiki.key)"
  assert_contains "$out" "  https://wiki.test:$p/"
  pass '--tls-cert and --tls-key serve HTTPS from wiki-server on 0.0.0.0, probed with curl --insecure, the port opened, the files remembered'

  # Remembered; then one .pem for both, checked against the authority that
  # signed it, for the name it is for; then against another, which warns.
  : >"$EVENTS"
  deploy --no-build >"$case_dir/again" 2>&1 || fail 'a redeploy with the remembered certificate failed'
  assert_contains "$HOME/$unit" "--listen 0.0.0.0:$p --admin-listen 127.0.0.1:$a --tls-cert \"$certs/wiki.crt\""
  out=$case_dir/pem
  deploy --no-build --tls-cert "$certs/wiki.pem" --tls-key "$certs/wiki.pem" --tls-ca "$certs/ca.crt" >"$out" 2>&1 || fail 'a redeploy with one .pem failed'
  assert_contains "$HOME/$unit" "--tls-cert \"$certs/wiki.pem\" --tls-key \"$certs/wiki.pem\""
  assert_contains "$EVENTS" "curl-tls https://wiki.test:$p/api/v1/info cacert=$certs/ca.crt connect=wiki.test:$p:127.0.0.1:$p insecure="
  assert_contains "$out" "its certificate verifies against $certs/ca.crt for wiki.test"
  [ "$(state tls_ca)" = "$certs/ca.crt" ] || fail 'the authority was not remembered'
  out=$case_dir/other-ca
  deploy --no-build --tls-ca "$certs/other-ca.crt" >"$out" 2>&1 || fail 'a certificate that does not verify failed the deploy'
  assert_contains "$out" "warning: its certificate does not verify against --tls-ca $certs/other-ca.crt for the name wiki.test"
  assert_contains "$HOME/$unit" "--tls-cert \"$certs/wiki.pem\""
  deploy --status >"$case_dir/status-ca" 2>&1
  assert_contains "$case_dir/status-ca" "checked against --tls-ca $certs/other-ca.crt"
  pass 'the certificate is remembered; one .pem serves as both; --tls-ca checks it for its name, and warns when it does not verify'

  # Back to tailscale serve: the certificate is dropped, the address goes
  # back to 127.0.0.1 and the port's rule is closed. On another port, as
  # the one on 0.0.0.0 holds 127.0.0.1 too until it stops.
  p2=$(other_port "$p")
  : >"$EVENTS"
  out=$case_dir/https
  deploy --no-build --https --port "$p2" >"$out" 2>&1 || fail '--https after a certificate failed'
  assert_contains "$out" "no longer serving with the certificate $certs/wiki.pem: --https replaces --tls-cert"
  assert_contains "$HOME/$unit" "--listen 127.0.0.1:$p2 --admin-listen 127.0.0.1:$a --secure-cookies"
  assert_lacks "$HOME/$unit" 'tls-cert'
  assert_contains "$EVENTS" "tailscale serve --bg http://127.0.0.1:$p2"
  assert_contains "$EVENTS" "ufw delete allow in on tailscale0 to any port $p proto tcp"
  { [ "$(state way)" = tailscale ] && [ -z "$(state tls_cert)" ] && [ -z "$(state tls_ca)" ]; } || fail 'state still records the certificate'
  undeploy >/dev/null 2>&1
  pass '--https leaves the certificate: back behind tailscale serve on 127.0.0.1, the rule closed'

  # The ways exclude each other, and the certificate needs both files, a
  # server, and files that can be read; all refused before anything is
  # built.
  fixture tls-refused
  p=$(free_port 127.0.0.1)
  refused() {
    out=$case_dir/refused
    if deploy --port "$p" "$@" >"$out" 2>&1; then fail "deploy $* was taken"; fi
    assert_contains "$out" "$refusal"
  }
  refusal='--https and --tls-cert are ways to serve that exclude each other'
  refused --https --tls-cert "$certs/wiki.crt" --tls-key "$certs/wiki.key"
  refusal='--tls-cert and --behind-proxy are ways to serve that exclude each other'
  refused --tls-cert "$certs/wiki.crt" --tls-key "$certs/wiki.key" --behind-proxy
  refusal='--http and --behind-proxy are ways to serve that exclude each other'
  refused --http --behind-proxy
  refusal='--tls-cert needs --tls-key FILE'
  refused --server --sqlite --tls-cert "$certs/wiki.crt"
  refusal="cannot read --tls-key $certs/missing.key"
  refused --server --sqlite --tls-cert "$certs/wiki.crt" --tls-key "$certs/missing.key"
  refusal='--tls-ca is the authority the deploy checks the server'"'"'s own certificate against'
  refused --server --sqlite --tls-ca "$certs/ca.crt"
  refusal="the demo's static server speaks plain HTTP, so --tls-cert is for the wiki's server"
  refused --static --tls-cert "$certs/wiki.crt" --tls-key "$certs/wiki.key"
  assert_lacks "$EVENTS" 'bootstrap'
  assert_lacks "$EVENTS" 'npm'
  [ ! -f "$HOME/.config/wiki-demo/wiki-demo.state" ] || fail 'a refused deploy wrote a state'
  pass 'the ways to serve exclude each other, and a certificate needs its key, a server and readable files, before anything is built'

  # Certificate files inside the deployment's directory, which the install
  # empties but for data/, state/ and toolchain/: refused before the
  # service is stopped, under the home directory and under a prefix (there
  # through a link from outside); under data/tls/ they are kept, and taken.
  fixture tls-inside
  p=$(free_port 127.0.0.2)
  a=$(other_port "$p")
  deploy --server --sqlite --http --port "$p" --admin-port "$a" >"$case_dir/first" 2>&1 || fail 'the plain HTTP deploy failed'
  cp "$certs/wiki.crt" "$certs/wiki.key" "$HOME/wiki-demo/"
  cp "$HOME/.config/wiki-demo/wiki-demo.state" "$case_dir/state-before"
  : >"$EVENTS"
  out=$case_dir/refused
  if deploy --no-build --tls-cert "$HOME/wiki-demo/wiki.crt" --tls-key "$HOME/wiki-demo/wiki.key" >"$out" 2>&1; then
    fail 'certificate files the install would delete were taken'
  fi
  assert_contains "$out" "the TLS file $HOME/wiki-demo/wiki.crt is inside $HOME/wiki-demo, which installing empties but for data/, state/ and toolchain/, so it would be deleted: keep it in $HOME/wiki-demo/data/tls/ or outside $HOME/wiki-demo"
  assert_lacks "$EVENTS" 'systemctl stop'
  cmp -s "$HOME/.config/wiki-demo/wiki-demo.state" "$case_dir/state-before" || fail 'a refused deploy changed the state'
  [ -f "$HOME/wiki-demo/wiki.key" ] || fail 'a refused deploy deleted the key'
  [ "$(http_get "http://127.0.0.2:$p/api/v1/info")" = '200 application/json' ] || fail 'the service stopped answering'
  mkdir -p "$HOME/wiki-demo/data/tls"
  mv "$HOME/wiki-demo/wiki.crt" "$HOME/wiki-demo/wiki.key" "$HOME/wiki-demo/data/tls/"
  out=$case_dir/kept
  deploy --no-build --tls-cert "$HOME/wiki-demo/data/tls/wiki.crt" --tls-key "$HOME/wiki-demo/data/tls/wiki.key" >"$out" 2>&1 ||
    fail 'certificate files under data/tls/ were refused'
  assert_contains "$HOME/$unit" "--tls-cert \"$HOME/wiki-demo/data/tls/wiki.crt\" --tls-key \"$HOME/wiki-demo/data/tls/wiki.key\""
  [ -f "$HOME/wiki-demo/data/tls/wiki.key" ] || fail 'the install deleted the key under data/tls/'
  [ "$(https_get "https://127.0.0.2:$p/api/v1/info")" = '200 application/json' ] || fail 'the server does not answer over HTTPS'
  undeploy >/dev/null 2>&1
  fixture tls-inside-prefix
  pre=$case_dir/srv
  q=$(free_port 127.0.0.2)
  b=$(other_port "$q")
  out=$case_dir/prefix-first
  deploy --server --sqlite --http --prefix "$pre" --port "$q" --admin-port "$b" >"$out" 2>&1 || fail 'the deploy under a prefix failed'
  cp "$certs/wiki.pem" "$pre/wiki.pem"
  ln -s "$pre/wiki.pem" "$case_dir/link.pem"
  : >"$EVENTS"
  out=$case_dir/prefix-refused
  if deploy --no-build --prefix "$pre" --tls-cert "$case_dir/link.pem" --tls-key "$case_dir/link.pem" >"$out" 2>&1; then
    fail 'a certificate linked into the prefix was taken'
  fi
  assert_contains "$out" "the TLS file $pre/wiki.pem is inside $pre, which installing empties"
  assert_lacks "$EVENTS" 'systemctl stop'
  [ -f "$pre/wiki.pem" ] || fail 'a refused deploy deleted the .pem under the prefix'
  undeploy --prefix "$pre" >/dev/null 2>&1
  pass 'certificate files the install would delete are refused before the service is stopped, through links and under a prefix too; under data/tls/ they are kept'
else
  printf 'skipped: openssl is not installed, so the cases of a certificate of its own (--tls-cert) do not run\n'
fi

# Behind a reverse proxy: from tailscale serve, which is turned off, to
# plain HTTP on 127.0.0.1 with Secure cookies and the proxy's needs
# printed; from --http, whose rule is closed; an address other than
# 127.0.0.1 refused.
fixture proxy
p=$(free_port 127.0.0.1)
a=$(other_port "$p")
deploy --server --sqlite --port "$p" --admin-port "$a" >"$case_dir/first" 2>&1 || fail 'the first deploy failed'
[ -s "$FAKE_TS_SERVE" ] || fail 'the first deploy did not set tailscale serve'
: >"$EVENTS"
out=$case_dir/proxy
deploy --no-build --behind-proxy >"$out" 2>&1 || fail 'the deploy behind a proxy failed'
assert_contains "$HOME/$unit" "--listen 127.0.0.1:$p --admin-listen 127.0.0.1:$a --secure-cookies --sqlite"
assert_contains "$EVENTS" 'tailscale serve --https=443 off'
[ ! -s "$FAKE_TS_SERVE" ] || fail '--behind-proxy left tailscale serve on'
assert_lacks "$EVENTS" 'ufw allow'
assert_lacks "$EVENTS" 'curl-tls'
assert_contains "$out" "answers on http://127.0.0.1:$p/api/v1/info"
assert_contains "$out" "It is behind a reverse proxy (--behind-proxy), which must:"
assert_contains "$out" 'send X-Forwarded-Proto and X-Forwarded-Host'
assert_contains "$out" "      reverse_proxy 127.0.0.1:$p"
assert_contains "$out" "  the reverse proxy's https:// address, which proxies to"
{ [ "$(state way)" = proxy ] && [ "$(state https)" = no ] && [ -z "$(state serve_port)" ]; } || fail 'state does not record the proxy'
deploy --status >"$case_dir/status" 2>&1
assert_contains "$case_dir/status" 'behind a reverse proxy (--behind-proxy): plain HTTP on 127.0.0.1'
out=$case_dir/refused
if deploy --no-build --bind 127.0.0.2 >"$out" 2>&1; then fail '--behind-proxy was taken with another address'; fi
assert_contains "$out" '--behind-proxy serves plain HTTP on 127.0.0.1, for a reverse proxy on this machine: drop --bind 127.0.0.2'
: >"$EVENTS"
deploy --no-build --http >"$case_dir/http" 2>&1 || fail '--http after the proxy failed'
assert_contains "$case_dir/http" 'no longer behind a reverse proxy: --http replaces --behind-proxy'
assert_contains "$HOME/$unit" "--listen 127.0.0.2:$p"
assert_contains "$EVENTS" "ufw allow in on tailscale0 to any port $p proto tcp comment wiki-demo"
: >"$EVENTS"
deploy --no-build --behind-proxy >"$case_dir/proxy-again" 2>&1 || fail '--behind-proxy after --http failed'
assert_contains "$HOME/$unit" "--listen 127.0.0.1:$p --admin-listen 127.0.0.1:$a --secure-cookies"
assert_contains "$EVENTS" "ufw delete allow in on tailscale0 to any port $p proto tcp"
[ -z "$(state rule_port)" ] || fail 'the rule was kept behind the proxy'
undeploy >/dev/null 2>&1
pass '--behind-proxy serves plain HTTP on 127.0.0.1 with Secure cookies, turns tailscale serve off, closes the rule and says what the proxy must do'

# The demo behind a reverse proxy too.
fixture proxy-demo
p=$(free_port 127.0.0.1)
out=$case_dir/out
deploy --static --behind-proxy --port "$p" >"$out" 2>&1 || fail 'the demo behind a proxy failed'
assert_contains "$HOME/$unit" "--port $p --bind 127.0.0.1"
assert_lacks "$EVENTS" 'tailscale serve'
assert_contains "$out" "      reverse_proxy 127.0.0.1:$p"
undeploy >/dev/null 2>&1
pass 'the demo is served behind a reverse proxy as the server is'

# The wizard, toolchain/configure.hs, knows the deploy's options: every
# option the header of deploy-local.sh describes is a string literal of the
# wizard, and every option literal of the wizard is in the header, so that
# a new option of the deploy cannot be missing from the wizard, nor a gone
# one stay in it. Left out on purpose: --force, which does nothing any more
# and which the wizard does not offer; and the wizard's own --args-from and
# --help. --dir, the old name of --prefix, is mentioned in the header's
# prose only.
wizard_options_differ() {
  sed -n '2,/^set -eu/p' "$SOURCE_DIR/deploy-local.sh" |
    sed -n 's/^#   \(--[a-z][a-z-]*\).*/\1/p' | grep -v -x -e '--force' | sort -u >"$TMP/header-options"
  grep -o '"--[a-z][a-z-]*' "$1" | sed 's/^"//' | grep -v -x -e '--args-from' -e '--help' | sort -u >"$TMP/wizard-options"
  [ "$(wc -l <"$TMP/header-options")" -ge 20 ] || fail "the deploy's header lists too few options; did its format change? $(cat "$TMP/header-options")"
  comm -23 "$TMP/header-options" "$TMP/wizard-options" >"$TMP/not-in-wizard"
  comm -13 "$TMP/header-options" "$TMP/wizard-options" >"$TMP/not-in-header"
  [ -s "$TMP/not-in-wizard" ] || [ -s "$TMP/not-in-header" ]
}
if wizard_options_differ "$SOURCE_DIR/configure.hs"; then
  fail "the wizard and the deploy's header differ: not in toolchain/configure.hs: $(cat "$TMP/not-in-wizard"); not in the header of deploy-local.sh: $(cat "$TMP/not-in-header")"
fi
# The comparison itself: an option taken out of a copy of the wizard, and
# one added to it, are both noticed.
sed 's/"--enable-linger/"--enable-lingering/g' "$SOURCE_DIR/configure.hs" >"$TMP/configure-changed.hs"
wizard_options_differ "$TMP/configure-changed.hs" || fail 'an option renamed in the wizard went unnoticed'
grep -x -e '--enable-linger' "$TMP/not-in-wizard" >/dev/null || fail 'the missing --enable-linger was not named'
grep -x -e '--enable-lingering' "$TMP/not-in-header" >/dev/null || fail 'the unknown --enable-lingering was not named'
pass 'the wizard offers every option of the deploy'"'"'s header but --force, and no other'

# The wizard's wrapper: toolchain/configure.sh checks the machine with the
# wizard's item (terminfo) and without libpq, runs the bootstrap's native
# mode for GHC and cabal with the same options, and then runs the wizard as
# a cabal script outside the project (-z), from the checkout's root, with
# its own arguments. The fake cabal records the call, and the first run is
# announced (the fake's list-bin names no program).
fixture configure
out=$case_dir/out
(cd "$case_dir" && sh "$case_dir/repo/toolchain/configure.sh" --args-from answers) >"$out" 2>&1 ||
  fail "the wrapper failed: $(cat "$out")"
assert_contains "$EVENTS" 'bootstrap native --without-postgres --with-wizard WIKI_TOOLCHAIN_HOME='
assert_contains "$EVENTS" "cabal run -z -v0 $case_dir/repo/toolchain/configure.hs -- --args-from answers"
[ "$(line_of "$EVENTS" 'bootstrap native')" -lt "$(line_of "$EVENTS" 'cabal run')" ] || fail 'the wizard ran before the bootstrap'
assert_contains "$out" 'configure: compiling the wizard: the first time, brick and vty as well'
assert_lacks "$out" 'warning'
# Without terminfo on a machine that is not Debian, the wrapper stops at
# the check, naming the packages, before the bootstrap or cabal.
: >"$EVENTS"
status=0
FAKE_NO_TINFO=1 PATH=$case_dir/bin:$NO_DPKG sh "$case_dir/repo/toolchain/configure.sh" >"$out" 2>&1 || status=$?
[ "$status" = 1 ] || fail "the wrapper without terminfo exited $status, not 1"
assert_contains "$out" 'missing  terminfo'
assert_contains "$out" 'sudo apt-get install libncurses-dev'
assert_contains "$out" 'sudo dnf install ncurses-devel'
assert_contains "$out" 'configure: the wizard is compiled on this machine with GHC, and the machine lacks what is listed above'
assert_contains "$out" 'skipped  libpq       not needed (built without PostgreSQL)'
assert_lacks "$EVENTS" 'bootstrap'
assert_lacks "$EVENTS" 'cabal'
# On Debian (a dpkg-query on PATH) a missing package is a warning: the
# bootstrap installs it, as the fake one installs zlib, and the wizard runs.
ln -s tool "$case_dir/bin/dpkg-query"
FAKE_NO_ZLIB=1 FAKE_BOOTSTRAP_ZLIB=$case_dir/zlib-installed sh "$case_dir/repo/toolchain/configure.sh" >"$out" 2>&1 ||
  fail "the wrapper on Debian without zlib failed: $(cat "$out")"
assert_contains "$out" 'configure: warning: the bootstrap installs the Debian packages missing above next'
assert_contains "$EVENTS" "cabal run -z -v0 $case_dir/repo/toolchain/configure.hs --"
sh "$case_dir/repo/toolchain/configure.sh" --help >"$out" 2>&1 || fail 'the wrapper'"'"'s --help failed'
assert_contains "$out" 'sh toolchain/configure.sh --args-from FILE'
pass 'toolchain/configure.sh checks the machine with terminfo and without libpq, runs bootstrap native --with-wizard, then the wizard through cabal run -z'

printf 'Passed %s deploy regression cases.\n' "$passed"
"$NODE_REAL" "$SOURCE_DIR/test-deploy-server.mjs"
if [ -n "$WIKI_SERVER" ] && [ -x "$WIKI_SERVER" ]; then
  "$NODE_REAL" "$SOURCE_DIR/test-deploy-server.mjs" --wiki-server "$WIKI_SERVER"
else
  printf 'FAIL: no wiki-server to run the static cases against: npm run build-native, or set WIKI_SERVER\n' >&2
  exit 1
fi
