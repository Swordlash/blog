#!/bin/sh
# Build the wiki and serve it from this machine, as a systemd user service:
# the wiki's server, wiki-server, with its data on this machine, or with
# --static the serverless demo as static files (whose home is GitHub Pages).
#
#   sh toolchain/deploy-local.sh [--server | --static] [--http | --https] [--port N]
#                                [--bind ADDRESS] [--admin-port N] [--dir DIR] [--name NAME]
#                                [--postgres | --sqlite] [--db-port N] [--fresh]
#                                [--no-build] [--no-firewall] [--enable-linger] [--force]
#   sh toolchain/deploy-local.sh --stop [--name NAME]
#   sh toolchain/deploy-local.sh --status [--name NAME]
#
# It is meant for a Linux machine of one's own reached over Tailscale (x86_64
# Debian or Ubuntu, as CI's runner), and does, in order:
#
#   1. Build: toolchain/bootstrap.sh (installs or checks the toolchain), npm ci
#      and `npm run build-wasm-opt`, the production build with every package at
#      -O2 (cabal-wasm-opt.project), into dist-newstyle/wasm-opt/public/app;
#      with --server also wiki-server, natively with this repository's packages
#      at -O2 (cabal-native-opt.project, into dist-newstyle/native-opt).
#      Any failure stops here, before the running service is touched.
#      With --server the wiki's database is PostgreSQL by default: the
#      postgres service of docker-compose.yml (postgres:17), run with Docker
#      as the compose project <name>, its data in the named volume
#      <name>_wiki-db, its port on 127.0.0.1 only (--db-port, default 5433).
#      The first run makes it, with a password of its own in
#      ~/.config/wiki-demo/<name>.postgres/db-password, and waits for its
#      health check; a later run finds it, and starts it if it was stopped.
#      A machine without Docker is refused, saying that --sqlite keeps the
#      database a file in data/ (wiki.sqlite) instead, with no container. A
#      data/ that holds a wiki.sqlite the deployment cannot use (one of a
#      wiki-server from before the schema of PostgreSQL and SQLite alike, or a
#      SQLite wiki when PostgreSQL is chosen) stops the deploy before anything
#      changes, with a warning: its content moves by an export with the
#      running server and an import into the new one. --fresh (or "yes" at
#      the question, on a terminal) goes on, moving the file aside into
#      data/replaced/<time>/, never deleting it.
#   2. Install: stop the running service; with --server, back its database up
#      (`wiki-server backup`, into data/backups/: VACUUM INTO on SQLite,
#      pg_dump on PostgreSQL, the container's own) with the new binary, and if
#      that fails start the old service again and stop. The new server then
#      brings the database's schema up to its own as it starts. Then empty the target
#      directory (default ~/<name>, so ~/wiki-demo) but for its data/, which
#      is never deleted, and copy into it the built page (app/), a brotli'd
#      copy of each compressible file beside it, and either a small static
#      server with no dependencies (server.mjs, from toolchain/deploy-server.mjs)
#      or, with --server, the server's binary (bin/wiki-server), so that the
#      service needs neither the checkout nor its node_modules. The directory
#      must be one this script made (it leaves a marker in it), empty, or new;
#      and it must be under your home directory unless --force.
#   3. Serve: write the systemd user unit <name>.service, which runs that
#      server (the static one with Node by absolute path, the one
#      toolchain/bootstrap.sh installs into ~/.wiki-toolchain, or else the Node
#      it found on PATH; or wiki-server, with --data <dir>/data, --listen on the
#      address and port, its admin listener on 127.0.0.1, and --secure-cookies
#      over HTTPS), enable it and (re)start it, and check that it answers.
#   4. HTTPS (the default): the server listens on 127.0.0.1 only, and
#      `tailscale serve --bg http://127.0.0.1:<port>` serves it to the tailnet
#      (never to the internet: no Funnel) at https://<machine>.<tailnet>.ts.net/,
#      tailscaled terminating TLS with a Let's Encrypt certificate it fetches
#      and renews itself. tailscaled keeps that configuration, so it is set
#      once and checked on every deploy (`tailscale serve status`). Setting it
#      needs root or tailscaled's operator (`sudo tailscale set
#      --operator=$USER`, once); without either, the command is printed for
#      you to run and the deploy goes on, answering on 127.0.0.1. Then it
#      checks that the HTTPS address answers (for up to a minute: the first
#      certificate takes a moment) and prints it first. It needs MagicDNS and
#      "HTTPS Certificates" on in the tailnet's DNS settings; without them it
#      says so and serves plain HTTP as --http does, until a later run finds
#      them. With --http it serves plain HTTP on the Tailscale address
#      instead, and turns off a serve an earlier deploy set.
#   5. Firewall, with --http: if ufw is installed and active, allow the port
#      on the Tailscale interface only, and delete the rule for the previous
#      port when the port changed, or when the address is 127.0.0.1 (as with
#      HTTPS), which needs none. Changes go through `sudo -n`; when sudo needs
#      a password the commands are printed for you to run instead.
#
# Running it again rebuilds and replaces the deployment: the old service stops
# before its files are replaced, the old port's rule is closed when the port
# changes, the service starts again on the new one, and the serve is left as
# it is when it already proxies to that port. Options not given are
# taken from the previous run (the state is kept in
# ~/.config/wiki-demo/<name>.state); the first run defaults to port 8080.
#
#   --server         deploy the wiki's server (wiki-server) with its data in <dir>/data
#                    (the first run's default); remembered for the next run
#   --static         deploy the serverless demo as static files instead, as GitHub Pages
#                    serves it; remembered for the next run; a server deployment's data/
#                    is kept, not deleted
#   --http           serve plain HTTP on the Tailscale address, without Secure cookies,
#                    for a tailnet without HTTPS certificates; remembered for the next run
#   --https          serve HTTPS through `tailscale serve` (the first run's default)
#   --port N         the port to serve on (1024-65535; default the previous one, or 8080)
#   --bind ADDRESS   the address to listen on: by default 127.0.0.1 behind tailscale
#                    serve, or with --http this machine's Tailscale IPv4 address
#                    (`tailscale ip -4`), or 127.0.0.1 with a warning when Tailscale
#                    does not answer; any address but 127.0.0.1 implies --http, and
#                    0.0.0.0 listens everywhere
#   --postgres       --server: keep the wiki in PostgreSQL, in Docker (the first run's
#                    default); remembered for the next run
#   --sqlite         --server: keep the wiki in data/wiki.sqlite instead, with no Docker
#                    and no second process; remembered for the next run
#   --db-port N      --server on PostgreSQL: the database's port on 127.0.0.1 (default the
#                    previous one, or 5433)
#   --fresh          --server: go on over a data/wiki.sqlite this deployment cannot use,
#                    moving it aside into data/replaced/<time>/ (export the wiki with the
#                    running server first, and import it into the new one after)
#   --admin-port N   --server: the port of the admin listener on 127.0.0.1, which serves
#                    the administration to whoever is on this machine (default the
#                    previous one, or 8081); from elsewhere, through
#                    ssh -L 8081:127.0.0.1:8081 <this machine>
#   --dir DIR        where to install (default the previous one, or ~/<name>)
#   --name NAME      the deployment, and its unit NAME.service (default wiki-demo);
#                    deployments with different names live side by side
#   --no-build       deploy the last -O2 build as it is, without the build step
#   --no-firewall    leave the firewall alone
#   --enable-linger  run `sudo loginctl enable-linger $USER`, so that the service
#                    starts at boot and survives logging out
#   --force          allow a target directory outside your home directory
#   --stop           take the deployment down (toolchain/undeploy-local.sh: stop and
#                    disable the service, remove its unit, close its port, turn its
#                    tailscale serve off; files and data kept)
#   --status         show the deployment and its service, change nothing
#
# The public address serves whoever signs in there, and anyone else as an
# anonymous reader. The first administrator is made on this machine, with the
# console, <dir>/bin/wiki (wiki-server with the deployment's database): <dir>/bin/wiki users add --data <dir>/data LOGIN --admin
# (it asks for the password); they then sign in at the public address. The
# --trust-network of earlier versions, which took everyone there for the
# administrator, is gone, and a deployment that had it loses it on its next
# run.
#
# The wiki's public address, the mail server invitations go through and the
# providers people sign in with are not options of this script nor of the
# server: they are set in the administration's "Server" section, on the
# admin listener (http://127.0.0.1:<admin-port>/admin/admin/), where they
# take effect at once and their secrets are kept in the wiki's database.
# Over HTTPS the script reminds you to set the public address to the HTTPS
# one when the section has none; the server answers feeds and the like from
# the address the request came to meanwhile.
# The --smtp-*, --public-url and --oidc options of earlier versions are
# refused, and a deployment that had them loses them on its next run, with
# the file of their secrets (~/.config/wiki-demo/<name>.env), and is told
# what to set in the panel instead.
set -eu

PROG=deploy-local
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=toolchain/deploy-lib.sh
. "$ROOT/toolchain/deploy-lib.sh"

usage() {
  sed -n '2,/^set -eu/{/^set -eu/d;s/^# \{0,1\}//;p;}' "$0"
}

name=wiki-demo
opt_port='' opt_bind='' opt_dir='' opt_mode='' opt_admin_port='' opt_https='' opt_db='' opt_db_port='' fresh=''
action=deploy
build=1 no_firewall='' enable_linger='' force=''
need_value() { [ "$1" -ge 2 ] || die "$2 needs a value"; }
while [ $# -gt 0 ]; do
  case $1 in
    --port) need_value $# "$1"; opt_port=$2; shift ;;
    --port=*) opt_port=${1#*=} ;;
    --bind) need_value $# "$1"; opt_bind=$2; shift ;;
    --bind=*) opt_bind=${1#*=} ;;
    --server) opt_mode=server ;;
    --static) opt_mode=static ;;
    --http) opt_https=no ;;
    --https) opt_https=yes ;;
    --admin-port) need_value $# "$1"; opt_admin_port=$2; shift ;;
    --admin-port=*) opt_admin_port=${1#*=} ;;
    --postgres) opt_db=postgres ;;
    --sqlite) opt_db=sqlite ;;
    --db-port) need_value $# "$1"; opt_db_port=$2; shift ;;
    --db-port=*) opt_db_port=${1#*=} ;;
    --fresh) fresh=1 ;;
    --smtp-host | --smtp-host=* | --smtp-port | --smtp-port=* | --smtp-security | --smtp-security=* | \
      --smtp-user | --smtp-user=* | --smtp-from | --smtp-from=* | --smtp-password | --smtp-password=* | \
      --public-url | --public-url=* | --oidc | --oidc=* | --oidc-secret | --oidc-secret=* | --no-smtp | --no-oidc)
      die "${1%%=*} is gone: the wiki's public address, its mail server and its sign-in providers are set in the administration's Server section, on the admin listener (http://127.0.0.1:<admin-port>/admin/admin/), where they take effect at once, without a deploy" ;;
    --trust-network | --no-trust-network)
      die "$1 is gone: the public address serves whoever signs in. Make an administrator with the console (<dir>/bin/wiki users add --data <dir>/data LOGIN --admin, which asks for the password) and sign in as them" ;;
    --dir) need_value $# "$1"; opt_dir=$2; shift ;;
    --dir=*) opt_dir=${1#*=} ;;
    --name) need_value $# "$1"; name=$2; shift ;;
    --name=*) name=${1#*=} ;;
    --no-build) build= ;;
    --no-firewall) no_firewall=1 ;;
    --enable-linger) enable_linger=1 ;;
    --force) force=1 ;;
    --stop) action=stop ;;
    --status) action=status ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done
check_name "$name"

if [ "$action" = stop ]; then
  undeploy
  exit 0
fi

prev_dir=$(state_get dir)
prev_port=$(state_get port)
prev_bind=$(state_get bind)
prev_bind_choice=$(state_get bind_choice)
prev_rule_port=$(state_get rule_port)
prev_mode=$(state_get mode)
# A deployment of a version before --server kept no mode, and was the demo:
# it stays one, whatever the first run's default is now.
if [ -z "$prev_mode" ] && [ -f "$state_file" ]; then
  prev_mode=static
fi
prev_admin_port=$(state_get admin_port)
prev_trust=$(state_get trust)
# Unset in a deployment of a version before HTTPS was the default, which
# then moves to it.
prev_https=$(state_get https)
prev_https_host=$(state_get https_host)
prev_serve_port=$(state_get serve_port)
# Unset in a server deployment of a version before PostgreSQL: its data/
# holds a wiki.sqlite of the earlier schema.
prev_db=$(state_get db)
prev_db_port=$(state_get db_port)
# What a deployment of an earlier version passed the server as options, which
# the administration's Server section now sets: told, and dropped, once.
prev_smtp_host=$(state_get smtp_host)
prev_smtp_port=$(state_get smtp_port)
prev_smtp_from=$(state_get smtp_from)
prev_public_url=$(state_get public_url)
prev_oidc=$(state_get oidc)
# The file an earlier version kept those options' secrets in, for the unit
# to read; nothing reads it any more, and the next deploy deletes it.
env_file=$STATE_DIR/$name.env

user=$(id -un)

# A word of a unit's ExecStart, quoted for systemd: in double quotes, with
# its quotes and backslashes escaped, and its % and $ doubled, which systemd
# would otherwise expand.
unit_word() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/[\\"]/\\&/g' -e 's/%/%%/g' -e 's/[$]/$$/g')"
}

# Where the deployment can be reached: the bind address, or for 0.0.0.0 the
# Tailscale address, and the MagicDNS name when Tailscale has one.
tailscale_ip() {
  command -v tailscale >/dev/null 2>&1 || return 1
  ip=$(timeout 10 tailscale ip -4 2>/dev/null | head -n 1) || return 1
  [ -n "$ip" ] && printf '%s\n' "$ip"
}
magicdns_name() {
  [ -n "${node:-}" ] && command -v tailscale >/dev/null 2>&1 || return 0
  timeout 10 tailscale status --json 2>/dev/null |
    "$node" -e 'let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
      try { process.stdout.write((JSON.parse(s).Self?.DNSName ?? "").replace(/\.$/, "")); } catch {}
    })' 2>/dev/null || true
}
# The MagicDNS name and whether HTTPS can be served on it, from `tailscale
# status --json`, as "<name> <magicdns> <certificates>": the name is
# Self.DNSName without its final dot ("-" for none), MagicDNS is off when
# CurrentTailnet.MagicDNSEnabled says so, and certificates are on when the
# name is among CertDomains, the names the coordination server helps get a
# certificate for, which it lists only when the tailnet has "HTTPS
# Certificates" on. Fails when Tailscale is not running.
tailscale_https() {
  command -v tailscale >/dev/null 2>&1 || return 1
  ts_json=$(timeout 10 tailscale status --json 2>/dev/null) || return 1
  printf '%s' "$ts_json" | "$node" -e 'let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
    let j;
    try { j = JSON.parse(s); } catch { process.exit(1); }
    if (j.BackendState && j.BackendState !== "Running") process.exit(1);
    const name = (j.Self?.DNSName ?? "").replace(/\.$/, "");
    const magic = j.CurrentTailnet?.MagicDNSEnabled === false ? "off" : "on";
    const certs = name && (j.CertDomains ?? []).includes(name) ? "on" : "off";
    console.log([name || "-", magic, certs].join(" "));
  })'
}
# The addresses to open, the one to use first: over HTTPS the MagicDNS name
# (https_host, with serve_note when the serve is not set yet), then the
# listener itself, on this machine.
print_urls() {
  if [ -n "${https_host:-}" ]; then
    printf '  https://%s/%s\n' "$https_host" "${serve_note:-}"
    printf '  http://127.0.0.1:%s/   (on this machine)\n' "$2"
    return 0
  fi
  case $1 in
    0.0.0.0 | ::) host=$(tailscale_ip || hostname) ;;
    *) host=$1 ;;
  esac
  case $host in *:*) host="[$host]" ;; esac
  printf '  http://%s:%s/\n' "$host" "$2"
  dns=$(magicdns_name)
  case $1 in
    127.0.0.1 | ::1) ;;
    *) [ -z "$dns" ] || printf '  http://%s:%s/\n' "$dns" "$2" ;;
  esac
}

linger_report() {
  linger=$(loginctl show-user "$user" -p Linger 2>/dev/null | sed -n 's/^Linger=//p' || true)
  case $linger in
    yes) say "lingering is on for $user: the service starts at boot and survives logging out" ;;
    no)
      if [ -n "$enable_linger" ]; then
        say "sudo loginctl enable-linger $user"
        if sudo loginctl enable-linger "$user"; then
          say "lingering is now on: the service starts at boot and survives logging out"
        else
          warn "could not enable lingering; run: sudo loginctl enable-linger $user"
        fi
      else
        say "lingering is off for $user: the service stops when you log out and does not start at boot."
        say "  To keep it running: sudo loginctl enable-linger $user   (or rerun with --enable-linger)"
      fi
      ;;
    *) say "cannot tell whether lingering is on for $user (loginctl show-user $user -p Linger); without it the service stops when you log out" ;;
  esac
}

# The URL of the deployment's PostgreSQL database, without its password,
# which is in the file pg_files writes.
db_url() { printf 'postgres://wiki@127.0.0.1:%s/wiki\n' "$db_port"; }

# The deployment's PostgreSQL files ('pg_dir'): a copy of
# docker-compose.yml, whose postgres service runs the database; local.yml,
# which publishes its port on this machine's loopback for the server; the
# database's password, made once and kept; and pg_dump and pg_restore,
# which run the container's own, of the server's major version (a pg_dump
# older than the server refuses it), for the backups the server makes.
pg_files() {
  pd=$(pg_dir)
  mkdir -p "$pd"
  chmod 700 "$pd"
  cp "$ROOT/docker-compose.yml" "$pd/docker-compose.yml"
  cat >"$pd/local.yml" <<EOF
# Written by toolchain/deploy-local.sh for the deployment $name: the
# database's port, published on this machine's loopback for the wiki's
# server, which runs as the systemd user service $name.service.
services:
  postgres:
    ports:
      - "127.0.0.1:\${WIKI_DB_PORT}:5432"
EOF
  if [ ! -s "$pd/db-password" ]; then
    (umask 077 && od -An -tx1 -N24 /dev/urandom | tr -d ' \n' >"$pd/db-password")
  fi
  for program in pg_dump pg_restore; do
    cat >"$pd/$program" <<EOF
#!/bin/sh
# $program of the PostgreSQL container of the deployment $name, written by
# toolchain/deploy-local.sh: wiki-server runs it for a backup or a restore
# with --dbname=<the URL it connects to>, which is this machine's address of
# the container; inside the container the program connects to its own
# socket instead, as the user wiki, to the database wiki.
n=\$#
named=
while [ "\$n" -gt 0 ]; do
  arg=\$1
  shift
  n=\$((n - 1))
  case \$arg in
    --dbname=*) named=1 ;;
    *) set -- "\$@" "\$arg" ;;
  esac
done
[ -z "\$named" ] || set -- --username=wiki --dbname=wiki "\$@"
WIKI_DB_PASSWORD_FILE='$pd/db-password' WIKI_DB_PORT='$db_port' exec docker compose --project-name '$name' \\
  --file '$pd/docker-compose.yml' --file '$pd/local.yml' exec -T postgres $program "\$@"
EOF
    chmod 700 "$pd/$program"
  done
}

# The console of a deployment, <dir>/bin/wiki: wiki-server with the
# deployment's database, for `users`, `backup`, `restore` and `oidc check`
# with --data alone. The database is given in the environment, which
# wiki-server reads when no option names one, and never on a command line.
console_wrapper() {
  printf '#!/bin/sh\n'
  printf '# wiki-server with the database of the deployment %s, written by\n' "$name"
  printf '# toolchain/deploy-local.sh. For example: %s/bin/wiki users list --data %s/data\n' "$dir" "$dir"
  if [ "$db" = postgres ]; then
    printf "WIKI_DATABASE_URL='%s'\n" "$(db_url)"
    printf "WIKI_DATABASE_PASSWORD_FILE='%s'\n" "$(pg_dir)/db-password"
    printf "WIKI_PG_DUMP='%s'\n" "$(pg_dir)/pg_dump"
    printf "WIKI_PG_RESTORE='%s'\n" "$(pg_dir)/pg_restore"
    printf 'export WIKI_DATABASE_URL WIKI_DATABASE_PASSWORD_FILE WIKI_PG_DUMP WIKI_PG_RESTORE\n'
  else
    printf '# The database is the SQLite file in the data directory.\n'
    printf 'unset WIKI_DATABASE_URL WIKI_DATABASE_PASSWORD_FILE\n'
  fi
  printf "exec '%s/bin/wiki-server' \"\$@\"\n" "$dir"
}

if [ "$action" = status ]; then
  if [ ! -f "$state_file" ] && [ ! -f "$unit_file" ]; then
    say "nothing is deployed under the name $name"
    exit 0
  fi
  say "deployment $name: $prev_dir, on $prev_bind:$prev_port"
  if [ "$prev_mode" = server ]; then
    say "the wiki's server, its data in $prev_dir/data; its admin listener on 127.0.0.1:$prev_admin_port"
    case $prev_db in
      postgres)
        say "its database: PostgreSQL in Docker, the compose project $name, on 127.0.0.1:$prev_db_port, its data in the volume ${name}_wiki-db"
        db=$prev_db db_port=$prev_db_port
        if docker_ready; then
          pg_compose ps postgres 2>/dev/null | sed 's/^/    /' || true
        else
          say "Docker does not answer, so the container's state is not known"
        fi ;;
      sqlite) say "its database: SQLite, $prev_dir/data/wiki.sqlite" ;;
      *) say "its database: $prev_dir/data/wiki.sqlite, of a version before PostgreSQL; the next deploy asks what to do with it" ;;
    esac
    [ "$prev_trust" != yes ] || say "it was deployed with --trust-network, which is gone: the next deploy serves the public address to whoever signs in there"
    backups=$(ls "$prev_dir/data/backups" 2>/dev/null | grep -c '[.]\(sqlite\|pgdump\)$' || true)
    latest=$(ls "$prev_dir/data/backups" 2>/dev/null | grep '[.]\(sqlite\|pgdump\)$' | tail -n 1 || true)
    say "backups: ${backups:-0} in $prev_dir/data/backups${latest:+, the latest $latest}"
    say "users: $prev_dir/bin/wiki users list --data $prev_dir/data (the first administrator: users add --data $prev_dir/data LOGIN --admin)"
    say "its public address, mail server and sign-in providers: the administration's Server section, http://127.0.0.1:$prev_admin_port/admin/admin/"
    if [ -n "$prev_smtp_host$prev_public_url$prev_oidc" ] || [ -f "$env_file" ]; then
      say "it was deployed with --smtp-host, --public-url or --oidc, which are gone: the next deploy drops them${prev_smtp_host:+ (mail through $prev_smtp_host)}${prev_oidc:+ (providers: $prev_oidc)}; set them in the Server section"
    fi
  else
    say "the serverless demo, as static files"
    [ ! -d "$prev_dir/data" ] || say "a server's data is kept in $prev_dir/data"
  fi
  https_host=$prev_https_host serve_note=
  if [ -n "$prev_serve_port" ]; then
    if ! serve_read; then
      say "HTTPS at https://$https_host/ through tailscale serve, whose status Tailscale does not give now"
      serve_note='   (tailscale serve status does not answer)'
    elif serve_proxies_to "$prev_serve_port"; then
      say "HTTPS at https://$https_host/: tailscale serve proxies it to 127.0.0.1:$prev_serve_port"
      [ "$serve_funnel" != funnel ] || warn "Funnel is on for it: the wiki is public on the internet, not only on your tailnet"
    else
      say "HTTPS at https://$https_host/ is not set: tailscale serve does not proxy to 127.0.0.1:$prev_serve_port (tailscale serve --bg http://127.0.0.1:$prev_serve_port would)"
      serve_note='   (once tailscale serve is set)'
    fi
    if [ -n "${serve_text:-}" ]; then
      printf '%s\n' "$serve_text" | sed 's/^/    /'
    fi
  elif [ "$prev_https" = no ]; then
    say "plain HTTP (--http): no tailscale serve, no Secure cookies"
  elif [ -n "$prev_https" ]; then
    say "HTTPS was asked for but not available at the last deploy (MagicDNS, HTTPS Certificates or Tailscale were off): plain HTTP until a deploy finds them"
  fi
  if [ -n "$prev_rule_port" ]; then
    say "firewall: a ufw rule for port $prev_rule_port on $TS_IFACE was opened (or printed) by this script"
  else
    say "firewall: no rule opened by this script"
  fi
  if [ -f "$unit_file" ]; then
    systemctl --user status "$name.service" --no-pager || true
  else
    say "$name.service is not installed (taken down with --stop or undeploy-local)"
  fi
  linger_report
  if [ -n "$prev_port" ]; then
    node=$(command -v "$HOME/.wiki-toolchain/node/bin/node" node 2>/dev/null | head -n 1 || true)
    printf 'Open:\n'
    print_urls "$prev_bind" "$prev_port"
    [ "$prev_mode" != server ] || printf 'Administration, on this machine: http://127.0.0.1:%s/admin/\n' "$prev_admin_port"
  fi
  exit 0
fi

# Everything that can be checked is checked before the build, which takes
# minutes (over an hour the first time), and the build before the running
# service is touched.

[ "$(id -u)" != 0 ] || die "run this as the user the wiki should run as, not root: it installs a systemd user service under that user"
require_systemd_user

port=${opt_port:-${prev_port:-8080}}
case $port in
  '' | 0* | *[!0-9]*) die "invalid --port '$port': a number from 1024 to 65535" ;;
esac
{ [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; } || die "invalid --port $port: a number from 1024 to 65535 (lower ports need root)"

# The first run deploys the server: the demo's home is GitHub Pages, and a
# machine of one's own is for a wiki that keeps what is written in it. A
# later run keeps what the previous one deployed.
mode=${opt_mode:-${prev_mode:-server}}
admin_port=${opt_admin_port:-${prev_admin_port:-8081}}
case $admin_port in
  '' | 0* | *[!0-9]*) die "invalid --admin-port '$admin_port': a number from 1024 to 65535" ;;
esac
{ [ "$admin_port" -ge 1024 ] && [ "$admin_port" -le 65535 ]; } || die "invalid --admin-port $admin_port: a number from 1024 to 65535"
if [ "$mode" = server ]; then
  [ "$admin_port" != "$port" ] || die "--admin-port and --port are both $port: choose two ports"
else
  [ -z "$opt_admin_port" ] || die "--admin-port is for the wiki's server: add --server"
  [ -z "$opt_db$opt_db_port$fresh" ] || die "--postgres, --sqlite, --db-port and --fresh are for the wiki's server: add --server"
fi

# The wiki's database: PostgreSQL in Docker unless --sqlite said otherwise,
# now or on an earlier run. The demo keeps what a server before it chose,
# for the server deployed after it.
db=$prev_db db_port=$prev_db_port
if [ "$mode" = server ]; then
  db=${opt_db:-${prev_db:-postgres}}
  if [ "$db" = postgres ]; then
    db_port=${opt_db_port:-${prev_db_port:-5433}}
    case $db_port in
      '' | 0* | *[!0-9]*) die "invalid --db-port '$db_port': a number from 1024 to 65535" ;;
    esac
    { [ "$db_port" -ge 1024 ] && [ "$db_port" -le 65535 ]; } || die "invalid --db-port $db_port: a number from 1024 to 65535"
    { [ "$db_port" != "$port" ] && [ "$db_port" != "$admin_port" ]; } || die "--db-port $db_port is the port of a listener: choose another"
    docker_ready || die "the wiki's database is PostgreSQL, which runs in Docker (docker compose), and Docker is not installed here or does not answer (docker info): install Docker and its compose plugin, or deploy with --sqlite, which keeps the database a file in the data directory, with no container"
  else
    [ -z "$opt_db_port" ] || die "--db-port is for a database on PostgreSQL: drop --sqlite"
  fi
fi

# The directory, absolute and with symbolic links resolved, so that the
# safety checks compare what would really be deleted.
dir=${opt_dir:-${prev_dir:-$HOME/$name}}
case $dir in
  /*) ;;
  *) dir=$PWD/$dir ;;
esac
dir=$(realpath -m "$dir")
case $dir in
  *[\"\\\$%\`]* | *'
'*) die "the target directory $dir contains a character the unit file cannot hold (\" \\ \$ % \` or a newline)" ;;
esac
if unsafe_dir "$dir"; then
  die "refusing to install into $dir: it is /, your home directory or above it"
fi
case $dir in
  "$(realpath -m "$HOME")"/*) ;;
  *) [ -n "$force" ] || die "refusing to install into $dir: it is outside your home directory (--force allows that)" ;;
esac
if [ -e "$dir" ] && [ ! -d "$dir" ]; then
  die "refusing to install into $dir: it is not a directory"
fi
if [ -d "$dir" ] && [ -n "$(ls -A "$dir")" ] && ! marked_for "$dir" "$name"; then
  if [ -f "$dir/$MARKER" ]; then
    die "refusing to install into $dir: it holds the deployment '$(state_get name "$dir/$MARKER")'; use --name $(state_get name "$dir/$MARKER") or another --dir"
  fi
  die "refusing to empty $dir: this script did not create it (it has no $MARKER). Choose another --dir, or empty or remove it yourself"
fi

# A server's data stays where it is: moving the deployment would leave it
# behind and start an empty wiki in the new place.
if [ "$mode" = server ] && [ -n "$prev_dir" ] && [ "$prev_dir" != "$dir" ] && [ -d "$prev_dir/data" ] && [ ! -d "$dir/data" ]; then
  die "the wiki's data is in $prev_dir/data: move it to $dir/data yourself first (with the service stopped: sh toolchain/undeploy-local.sh --name $name), or deploy under another --name"
fi

# HTTPS unless --http says otherwise, now or on an earlier run; a
# deployment of a version before it was the default moves to it.
https=${opt_https:-${prev_https:-yes}}
# The previous run's address is kept when it was asked for (but not an
# address --https cannot serve behind tailscale serve); one chosen
# automatically is chosen again, as Tailscale may have come up since.
if [ -n "$opt_bind" ]; then
  bind=$opt_bind bind_choice=explicit
elif [ "$prev_bind_choice" = explicit ] && [ -n "$prev_bind" ] &&
  ! { [ "$opt_https" = yes ] && [ "$prev_bind" != 127.0.0.1 ]; }; then
  bind=$prev_bind bind_choice=explicit
else
  bind_choice=auto bind=
fi
case $bind in
  *[!0-9A-Fa-f.:]*) die "invalid --bind '$bind': an IPv4 or IPv6 address" ;;
esac
# tailscale serve proxies to 127.0.0.1, so any other address is plain HTTP.
if [ -n "$bind" ] && [ "$bind" != 127.0.0.1 ] && [ "$https" = yes ]; then
  [ "$opt_https" != yes ] || die "--https serves from 127.0.0.1 behind tailscale serve: drop --bind $bind, or give --bind 127.0.0.1"
  say "--bind $bind implies --http: tailscale serve proxies to 127.0.0.1 only"
  https=no
fi
if [ -z "$bind" ]; then
  if [ "$https" = yes ]; then
    # Settled once Node is at hand, below: HTTPS may turn out not to be
    # available, and then the Tailscale address serves plain HTTP.
    bind=127.0.0.1
  elif bind=$(tailscale_ip); then
    say "listening on the Tailscale address $bind"
  else
    bind=127.0.0.1
    warn "Tailscale does not answer (tailscale ip -4), so listening on 127.0.0.1 only; rerun when it is up, or choose with --bind (0.0.0.0 listens everywhere)"
  fi
fi

out=$ROOT/dist-newstyle/wasm-opt/public/app

# The application a deployment serves: the -O2 build of wiki-app into $out.
# This is the one place that says how it is built, for the demo and the server
# alike. The binary is the same; the pages differ (toolchain/build-wasm.sh):
# the demo's keep the wiki in the browser (MemWiki), one prerendered page per
# route, and the server's ($mode = server) talk to wiki-server over HTTP
# (HttpWiki), with one page, the application before it has loaded anything,
# which the server serves at every address.
build_app() {
  if [ "$mode" = server ]; then backend=server; else backend=demo; fi
  (cd "$ROOT" && HALOGEN_BASE_PATH=/ WIKI_BACKEND=$backend npm run build-wasm-opt)
}

# wiki-server, natively, with this repository's packages at -O2 and the
# dependencies as the everyday build has them (cabal-native-opt.project), in a
# build directory of its own so that neither build invalidates the other.
server_cabal() {
  (cd "$ROOT" && cabal "$1" -v0 --project-file=cabal-native-opt.project --builddir=dist-newstyle/native-opt wiki-server:exe:wiki-server)
}

if [ -n "$build" ]; then
  if [ ! -d "$ROOT/dist-newstyle/wasm-opt" ]; then
    say "first -O2 build: every dependency is compiled again at -O2 for wasm, ghc-lib-parser among them (13.5 minutes at the default level alone), so this can take over an hour once; later runs rebuild only what changed."
  fi
  say "installing or checking the toolchain (toolchain/bootstrap.sh toolchain)"
  sh "$ROOT/toolchain/bootstrap.sh" toolchain
fi
# The environment npm's own entry points load, for npm and Node here.
if [ -r "$HOME/.wiki-toolchain/env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.wiki-toolchain/env"
fi
bootstrap_env=$(sh "$ROOT/toolchain/bootstrap.sh" env)
eval "$bootstrap_env"
if [ -n "$build" ]; then
  say "npm ci"
  (cd "$ROOT" && npm ci --no-audit --no-fund)
  say "building the application (npm run build-wasm-opt)"
  # The wiki is served at the root of its own port.
  build_app
  if [ "$mode" = server ]; then
    say "building wiki-server at -O2 (cabal-native-opt.project)"
    server_cabal build
  fi
fi
for file in index.html 404.html app.wasm; do
  [ -f "$out/$file" ] || die "the build in $out lacks $file; run without --no-build"
done
if [ "$mode" = server ]; then
  server_bin=$(server_cabal list-bin) && [ -x "$server_bin" ] ||
    die "there is no -O2 build of wiki-server (dist-newstyle/native-opt); run without --no-build"
fi

# The service's Node, by absolute path: the managed one if the bootstrap
# installed it, otherwise the one it found on PATH. The managed one is named
# through ~/.wiki-toolchain/node, the link the bootstrap moves to a new
# version, not the versioned directory behind it, which an upgrade leaves
# behind to be cleaned up.
if [ -x "$HOME/.wiki-toolchain/node/bin/node" ]; then
  node=$HOME/.wiki-toolchain/node/bin/node
elif node=$(command -v node); then
  node=$(realpath "$node")
  warn "using $node for the service; it must stay where it is (the bootstrap's own Node, in ~/.wiki-toolchain, would)"
else
  die "no Node to run the server with; run sh toolchain/bootstrap.sh"
fi

# Whether HTTPS can be served: it needs Tailscale running, with MagicDNS
# and certificates for this machine's name. Without them this deployment
# serves plain HTTP as --http would, but stays HTTPS by choice, so that a
# later run, once they are on, moves to it.
https_host=
if [ "$https" = yes ]; then
  dns_off="in the tailnet's DNS settings (https://login.tailscale.com/admin/dns)"
  if ! ts=$(tailscale_https); then
    warn "Tailscale does not answer (tailscale status), so cannot serve HTTPS through tailscale serve; listening on 127.0.0.1 only. Rerun when it is up, or deploy with --http"
  else
    read -r ts_name ts_magic ts_certs <<EOF
$ts
EOF
    if [ "$ts_name" = - ] || [ "$ts_magic" = off ]; then
      warn "MagicDNS is off, so this machine has no name to serve HTTPS on: turn on MagicDNS and HTTPS Certificates $dns_off and run this again. Serving plain HTTP meanwhile, as --http does"
    elif [ "$ts_certs" = off ]; then
      warn "the tailnet does not issue HTTPS certificates for $ts_name: turn on HTTPS Certificates $dns_off and run this again. Serving plain HTTP meanwhile, as --http does"
    else
      https_host=$ts_name
    fi
    if [ -z "$https_host" ] && [ "$bind_choice" = auto ]; then
      if bind=$(tailscale_ip); then
        say "listening on the Tailscale address $bind"
      else
        bind=127.0.0.1
      fi
    fi
  fi
fi
if [ -n "$https_host" ]; then
  say "serving HTTPS at https://$https_host/ through tailscale serve, from 127.0.0.1:$port"
  serve_port=$port
else
  serve_port=
fi

# A port another program holds would only show as a service failing to start
# after the old one is gone, so find out first. The running deployment's own
# port is not checked: it is about to be freed.
service_active() { systemctl --user is-active --quiet "$name.service" 2>/dev/null; }
can_listen() {
  "$node" -e '
    const server = require("node:net").createServer();
    server.once("error", (e) => { console.error(e.message); process.exit(1); });
    server.listen(Number(process.argv[1]), process.argv[2], () => server.close());
  ' "$1" "$2"
}
if ! { [ "$port" = "$prev_port" ] && [ "$bind" = "$prev_bind" ] && service_active; }; then
  can_listen "$port" "$bind" || die "cannot listen on $bind:$port (see above): choose another --port or --bind"
fi
if [ "$mode" = server ] && ! { [ "$prev_mode" = server ] && [ "$admin_port" = "$prev_admin_port" ] && service_active; }; then
  can_listen "$admin_port" 127.0.0.1 || die "cannot listen on 127.0.0.1:$admin_port (see above): choose another --admin-port"
fi

# The wiki's database. On PostgreSQL its files are written and its
# container is made, or started, and waited for; this changes nothing the
# running deployment uses. Then a data/wiki.sqlite this deployment cannot
# use stops the deploy, unless --fresh (or a "yes") moves it aside below.
if [ "$mode" = server ]; then
  if [ "$db" = postgres ]; then
    pg_files
    say "starting PostgreSQL in Docker (the compose project $name, on 127.0.0.1:$db_port) and waiting for it"
    pg_compose up --detach --wait postgres ||
      die "PostgreSQL did not start (see above): if the port is taken, choose another with --db-port, or deploy with --sqlite"
  fi
  # On SQLite, a file of the earlier schema is found by the backup below
  # (wiki-server backup exits with 3).
  incompatible=
  if [ -f "$dir/data/wiki.sqlite" ] && [ "$db" = postgres ]; then
    if [ -z "$prev_db" ]; then
      incompatible="$dir/data/wiki.sqlite holds a wiki of a wiki-server from before PostgreSQL (or one on SQLite), and this deployment keeps the wiki in PostgreSQL"
    else
      incompatible="$dir/data/wiki.sqlite holds the wiki in SQLite, and this deployment keeps it in PostgreSQL"
    fi
  fi
  # --fresh moves a data/wiki.sqlite aside whatever it holds.
  [ -z "$fresh" ] || [ ! -f "$dir/data/wiki.sqlite" ] || incompatible=${incompatible:-$dir/data/wiki.sqlite is set aside (--fresh)}
  if [ -n "$incompatible" ] && [ -z "$fresh" ]; then
    warn "the state is incompatible: $incompatible. Its content moves by export and import: export the wiki with the running server (Administration, Wiki data, Export the wiki), go on here, then import the archive into the new wiki (Administration, Wiki data, Import). Going on moves the file aside into $dir/data/replaced/<time>/; it is never deleted"
    if [ -t 0 ] && [ -t 1 ]; then
      printf '%s: type yes to move it aside and start an empty wiki: ' "$PROG"
      read -r answer || answer=
      [ "$answer" = yes ] || die "nothing was changed"
      fresh=1
    else
      die "nothing was changed: run this again with --fresh to move $dir/data/wiki.sqlite aside and start an empty wiki"
    fi
  fi
fi

# From here on the running deployment changes.

was_installed=
if [ -f "$unit_file" ]; then
  was_installed=1
  say "stopping $name.service"
  systemctl --user stop "$name.service" || true
fi
# The database is copied aside before the new server, which may migrate it,
# first opens it, and with the old one stopped, so that the copy has every
# write. If that fails, the old deployment goes on as it was.
if [ "$mode" = server ] && [ -n "$incompatible" ]; then
  aside=$dir/data/replaced/$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$aside"
  for file in wiki.sqlite wiki.sqlite-wal wiki.sqlite-shm; do
    [ ! -f "$dir/data/$file" ] || mv "$dir/data/$file" "$aside/"
  done
  say "moved $dir/data/wiki.sqlite aside into $aside: the new wiki starts empty"
fi
if [ "$mode" = server ]; then
  say "backing the database up into $dir/data/backups"
  status=0
  if [ "$db" = postgres ]; then
    "$server_bin" backup --data "$dir/data" --database "$(db_url)" --database-password-file "$(pg_dir)/db-password" \
      --pg-dump "$(pg_dir)/pg_dump" --pg-restore "$(pg_dir)/pg_restore" || status=$?
  else
    "$server_bin" backup --data "$dir/data" --sqlite "$dir/data/wiki.sqlite" || status=$?
  fi
  if [ "$status" != 0 ]; then
    if [ -n "$was_installed" ]; then
      systemctl --user start "$name.service" || true
    fi
    [ "$status" != 3 ] || die "the state is incompatible: the database is an earlier wiki-server's (see above), so nothing was changed. Export the wiki with the running server, run this again with --fresh, and import the archive into the new wiki"
    die "the backup of $dir/data failed (see above), so nothing was changed"
  fi
fi
if [ -n "$prev_dir" ] && [ "$prev_dir" != "$dir" ] && [ -d "$prev_dir" ]; then
  say "moving from $prev_dir to $dir: the old files stay in $prev_dir"
fi

if [ -z "$no_firewall" ]; then
  firewall_probe
  firewall_explain
fi
# The previous port's rule goes when the port changes, or when the new
# address is local only and needs none.
rule_port=$prev_rule_port
# The fallback address needs no rule.
case $bind in 127.0.0.1 | ::1) local_only=1 ;; *) local_only= ;; esac
if [ -n "$rule_port" ] && { [ "$rule_port" != "$port" ] || [ -n "$local_only" ]; }; then
  if [ -n "$no_firewall" ]; then
    say "--no-firewall: leaving the rule for port $rule_port as it is"
  else
    firewall_close "$rule_port"
    rule_port=
  fi
fi

say "installing into $dir"
mkdir -p "$dir"
# Everything but the data, which outlives every deployment of it.
find "$dir" -mindepth 1 -maxdepth 1 ! -name data -exec rm -rf {} +
printf 'name=%s\ncreated-by=toolchain/deploy-local.sh\n' "$name" >"$dir/$MARKER"
cp -R "$out" "$dir/app"
if [ "$mode" = server ]; then
  mkdir -p "$dir/bin" "$dir/data"
  chmod 700 "$dir/data"
  cp "$server_bin" "$dir/bin/wiki-server"
  console_wrapper >"$dir/bin/wiki"
  chmod 755 "$dir/bin/wiki"
else
  cp "$ROOT/toolchain/deploy-server.mjs" "$dir/server.mjs"
  [ ! -d "$dir/data" ] || say "keeping the server's data in $dir/data"
fi
# Precompressed copies, which the server sends to browsers that accept
# brotli: the build itself writes none, since GitHub Pages compresses on the
# fly (toolchain/build-wasm.sh).
find "$dir/app" -type f \( -name '*.wasm' -o -name '*.js' -o -name '*.mjs' -o -name '*.css' \
  -o -name '*.html' -o -name '*.svg' -o -name '*.json' \) -size +1k -print0 |
  xargs -0 -r "$node" "$ROOT/toolchain/compress.mjs" >/dev/null
say "copied the page and $(find "$dir/app" -name '*.br' | wc -l | tr -d ' ') brotli'd files"

case $bind in
  *:*) listen="[$bind]:$port" ;;
  *) listen=$bind:$port ;;
esac
if [ "$mode" = server ]; then
  description="Wiki server ($name) from $dir on $bind:$port"
  exec_start="\"$dir/bin/wiki-server\" serve --data \"$dir/data\" --static \"$dir/app\" --listen $listen --admin-listen 127.0.0.1:$admin_port"
  # A Secure cookie is sent over HTTPS only, so over plain HTTP it would
  # make signing in impossible: only behind tailscale serve. The admin
  # listener uses no cookie.
  [ -z "$https_host" ] || exec_start="$exec_start --secure-cookies"
  # The database: PostgreSQL by its URL, without the password, which is in
  # a file of the owner's; or the SQLite file in the data directory.
  if [ "$db" = postgres ]; then
    exec_start="$exec_start --database $(db_url) --database-password-file $(unit_word "$(pg_dir)/db-password") --pg-dump $(unit_word "$(pg_dir)/pg_dump") --pg-restore $(unit_word "$(pg_dir)/pg_restore")"
  else
    exec_start="$exec_start --sqlite $(unit_word "$dir/data/wiki.sqlite")"
  fi
  # The data is the owner's alone, and a stop lets the requests under way
  # finish (the server gives them ten seconds).
  service_extra="UMask=0077
TimeoutStopSec=30"
else
  description="Wiki demo ($name) from $dir on $bind:$port"
  exec_start="\"$node\" \"$dir/server.mjs\" --root \"$dir/app\" --port $port --bind $bind"
  service_extra=
fi

# The secrets an earlier version kept for the unit's environment: the
# server reads them from its database now, as the administration sets them.
if [ -f "$env_file" ]; then
  rm -f "$env_file"
  say "deleted $env_file: the mail password and providers' secrets it held are set in the administration's Server section now"
fi

mkdir -p "$UNIT_DIR"
cat >"$unit_file.tmp" <<EOF
# Written by toolchain/deploy-local.sh from $ROOT;
# run it again to change this deployment, or toolchain/undeploy-local.sh --name $name
# to take it down.
[Unit]
Description=$description
After=network-online.target
# Restart for as long as it takes: at boot the Tailscale address may appear a
# little after this starts, and listening on it fails until then.
StartLimitIntervalSec=0

[Service]
ExecStart=$exec_start
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
$service_extra

[Install]
WantedBy=default.target
EOF
mv "$unit_file.tmp" "$unit_file"
state_write
systemctl --user daemon-reload
systemctl --user enable "$name.service" >/dev/null 2>&1 || systemctl --user enable "$name.service"
say "starting $name.service"
systemctl --user restart "$name.service"

case $bind in
  0.0.0.0) probe_host=127.0.0.1 ;;
  ::) probe_host='[::1]' ;;
  *:*) probe_host="[$bind]" ;;
  *) probe_host=$bind ;;
esac
answers() {
  "$node" -e '
    fetch(process.argv[1]).then((r) => process.exit(r.status === 200 ? 0 : 1), () => process.exit(1));
  ' "$1" 2>/dev/null
}
if [ "$mode" = server ]; then probe_path=api/v1/info; else probe_path=; fi
waited=0
until service_active && answers "http://$probe_host:$port/$probe_path"; do
  waited=$((waited + 1))
  if [ "$waited" -ge "${WIKI_DEPLOY_WAIT:-20}" ]; then
    systemctl --user status "$name.service" --no-pager >&2 || true
    [ -n "$no_firewall" ] || firewall_report
    die "$name.service does not answer on http://$probe_host:$port/; see journalctl --user -u $name"
  fi
  sleep 1
done
say "$name.service answers on http://$probe_host:$port/$probe_path"
if [ "$mode" = server ]; then
  if answers "http://127.0.0.1:$admin_port/admin/api/v1/admin/status"; then
    say "its admin listener answers on http://127.0.0.1:$admin_port/admin/"
  else
    warn "its admin listener does not answer on http://127.0.0.1:$admin_port/admin/; see journalctl --user -u $name"
  fi
fi

# The version of the tailscale command when it is older than 1.52, whose
# `tailscale serve` took `https:443 / <target>` rather than --bg.
tailscale_old_version() {
  ts_version=$(timeout 10 tailscale version 2>/dev/null | head -n 1) || return 1
  case $ts_version in
    1.[0-9] | 1.[0-9].* | 1.[1-4][0-9] | 1.[1-4][0-9].* | 1.5[01] | 1.5[01].*) printf '%s\n' "$ts_version" ;;
    *) return 1 ;;
  esac
}
# Whether an HTTPS address answers 200, through curl when there is one, as
# you would check it by hand. Proxies are skipped: the MagicDNS name is
# resolved by tailscaled and reached over the tailnet.
https_answers() {
  if command -v curl >/dev/null 2>&1; then
    curl -fs -o /dev/null --max-time 10 --noproxy '*' "$1" 2>/dev/null
  else
    "$node" -e '
      fetch(process.argv[1], { signal: AbortSignal.timeout(10000) })
        .then((r) => process.exit(r.status === 200 ? 0 : 1), () => process.exit(1));
    ' "$1" 2>/dev/null
  fi
}

# tailscale serve. Over HTTPS: leave it when it already proxies to this
# port (an earlier deploy's, or set by hand), set it when it serves nothing
# at https://<name>/ or this deployment's previous port, and leave anything
# else there alone, saying so. Over plain HTTP: turn off the serve an
# earlier HTTPS deploy of this deployment set.
serve_state='' serve_note=''
if [ -n "$https_host" ]; then
  serve_cmd="serve --bg http://127.0.0.1:$port"
  if ! serve_read; then
    warn "tailscale serve status does not answer, so cannot serve https://$https_host/"
    serve_rights_hint "$serve_cmd"
  elif serve_proxies_to "$port"; then
    say "tailscale serve already proxies https://$https_host/ to 127.0.0.1:$port: leaving it as it is"
    serve_state=ours
  elif [ -n "$serve_type" ] && ! { [ -n "$prev_serve_port" ] && serve_proxies_to "$prev_serve_port"; } &&
    ! { [ -n "$prev_port" ] && serve_proxies_to "$prev_port"; }; then
    warn "https://$https_host/ already serves $serve_type $serve_target, which this deployment did not set, so it is left alone; to serve the wiki there instead, run: tailscale $serve_cmd (or deploy this one with --http)"
  elif ts_old=$(tailscale_old_version); then
    warn "this Tailscale ($ts_old) is older than 1.52, whose tailscale serve this script uses; upgrade it and run this again, or set the serve yourself with the older form:"
    printf '    sudo tailscale serve https:443 / http://127.0.0.1:%s\n' "$port"
  else
    say "tailscale $serve_cmd"
    if serve_out=$(timeout 60 tailscale serve --bg "http://127.0.0.1:$port" </dev/null 2>&1) && serve_read && serve_proxies_to "$port"; then
      say "tailscale serve proxies https://$https_host/ to 127.0.0.1:$port (tailnet only)"
      serve_state=ours
    else
      [ -z "$serve_out" ] || printf '%s\n' "$serve_out" | sed 's/^/    /' >&2
      warn "could not set tailscale serve (see above); the deployment answers on 127.0.0.1:$port meanwhile"
      serve_rights_hint "$serve_cmd"
    fi
  fi
  if [ "$serve_state" = ours ]; then
    [ "$serve_funnel" != funnel ] ||
      warn "Funnel is on for https://$https_host/ (tailscale serve status): the wiki is public on the internet, not only on your tailnet. This script never turns it on"
    # The first certificate is fetched as the first request arrives, which
    # takes a moment; tailscaled may hold that request's handshake while it
    # does, so the wait is counted by the clock rather than by attempts.
    started=$(date +%s) https_ok=
    while :; do
      if https_answers "https://$https_host/$probe_path"; then
        https_ok=1
        break
      fi
      [ "$(($(date +%s) - started))" -lt "${WIKI_DEPLOY_HTTPS_WAIT:-60}" ] || break
      sleep 2
    done
    if [ -n "$https_ok" ]; then
      say "it answers on https://$https_host/$probe_path"
    else
      warn "https://$https_host/ does not answer yet: the first certificate can take a minute or two to arrive; try it shortly (curl https://$https_host/), and see tailscale serve status"
    fi
  else
    serve_note='   (once tailscale serve is set: see above)'
  fi
elif [ -n "$prev_serve_port" ]; then
  serve_off "$prev_serve_port"
fi

if [ -z "$no_firewall" ] && [ -z "$local_only" ]; then
  firewall_open "$port"
  case $fw in active | locked | unknown) rule_port=$port ;; esac
  state_write
fi
[ -n "$no_firewall" ] || firewall_report
linger_report

# The public address the administration's Server section holds, read from
# the admin listener (empty for none); fails when it cannot be read.
panel_public_url() {
  "$node" -e '
    fetch(process.argv[1])
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
      .then((j) => process.stdout.write(j.publicUrl ?? ""), () => process.exit(1));
  ' "http://127.0.0.1:$admin_port/admin/api/v1/admin/server" 2>/dev/null
}

if [ "$mode" = server ]; then
  printf '\nThe wiki is served from %s, its data in %s/data. Open:\n' "$dir" "$dir"
  print_urls "$bind" "$port"
  if [ "$db" = postgres ]; then
    printf 'Its database is PostgreSQL in Docker (docker compose --project-name %s ps), on\n' "$name"
    printf '127.0.0.1:%s, its data in the volume %s_wiki-db; its password is in %s/db-password.\n' "$db_port" "$name" "$(pg_dir)"
  else
    printf 'Its database is SQLite, %s/data/wiki.sqlite.\n' "$dir"
  fi
  # The public address stays a setting of the panel (decision 11 of
  # docs/PLAN.md): the script only says what to set it to.
  if [ -n "$https_host" ]; then
    if ! public_url=$(panel_public_url); then
      printf 'If the administration'"'"'s Server section has no public address yet, set it to https://%s/\n' "$https_host"
      printf '  (http://127.0.0.1:%s/admin/admin/): mailed links and sign-in providers start with it.\n' "$admin_port"
    elif [ -z "$public_url" ]; then
      printf 'The wiki has no public address yet: set it to https://%s/ in the administration'"'"'s\n' "$https_host"
      printf 'Server section (http://127.0.0.1:%s/admin/admin/); mailed links and sign-in providers start with it.\n' "$admin_port"
    elif [ "${public_url%/}" != "https://$https_host" ]; then
      printf 'The public address in the administration'"'"'s Server section is %s, but the wiki\n' "$public_url"
      printf 'is served at https://%s/: change it there (http://127.0.0.1:%s/admin/admin/) if people use that one.\n' "$https_host" "$admin_port"
    fi
  fi
  cat <<EOF
Administration, on this machine only: http://127.0.0.1:$admin_port/admin/
  from another: ssh -L $admin_port:127.0.0.1:$admin_port $user@<this machine>, then the same address
Backups: $dir/data/backups (one before every deploy; another: $dir/bin/wiki backup --data $dir/data)
Users:   $dir/bin/wiki users list --data $dir/data
  the first administrator: $dir/bin/wiki users add --data $dir/data LOGIN --admin (asks for the password)
Logs:    journalctl --user -u $name -f
Status:  sh toolchain/deploy-local.sh --status --name $name
Stop:    sh toolchain/undeploy-local.sh --name $name   (--purge deletes the files but data/, --purge-data that too)
EOF
  printf '\nThe public address serves whoever signs in there, and anyone else as an anonymous\n'
  printf 'reader, who sees the public spaces only; the operator is on the admin listener.\n'
  printf 'Whether the wiki is open (anyone may make an account) or closed (by invitation\n'
  printf 'only, nothing shown to anyone not signed in) is the administration'"'"'s "Who may come in".\n'
  printf 'The wiki'"'"'s public address, the mail server invitations go through and the\n'
  printf 'providers people sign in with are set in its "Server" section, at\n'
  printf '  http://127.0.0.1:%s/admin/admin/\n' "$admin_port"
  printf 'where they take effect at once (check the providers: %s/bin/wiki oidc check --data %s/data).\n' "$dir" "$dir"
  if [ -n "$prev_smtp_host$prev_public_url$prev_oidc" ]; then
    printf '%s: the previous deployment passed the server --smtp-host, --public-url or --oidc,\n' "$PROG"
    printf '%s: which are gone; set them again in the Server section:\n' "$PROG"
    [ -z "$prev_public_url" ] || printf '%s:   the public address %s\n' "$PROG" "$prev_public_url"
    [ -z "$prev_smtp_host" ] || printf '%s:   mail through %s:%s, from %s (and its password)\n' "$PROG" "$prev_smtp_host" "${prev_smtp_port:-587}" "$prev_smtp_from"
    for provider in $prev_oidc; do
      printf '%s:   the provider %s (and its client secret)\n' "$PROG" "$provider"
    done
  fi
  if [ "$prev_trust" = yes ]; then
    printf '%s: the previous deployment took everyone at %s for the administrator\n' "$PROG" "$listen"
    printf '%s: (--trust-network); that is gone. Sign in as an administrator there, made with\n' "$PROG"
    printf '%s:   %s/bin/wiki users add --data %s/data LOGIN --admin\n' "$PROG" "$dir" "$dir"
  fi
else
  printf '\nThe demo is served from %s. Open:\n' "$dir"
  print_urls "$bind" "$port"
  cat <<EOF
Logs:    journalctl --user -u $name -f
Status:  sh toolchain/deploy-local.sh --status --name $name
Stop:    sh toolchain/undeploy-local.sh --name $name   (--purge also deletes $dir)
EOF
fi
